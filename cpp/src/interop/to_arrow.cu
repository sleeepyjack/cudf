/*
 * Copyright (c) 2020-2023, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <cudf/column/column.hpp>
#include <cudf/column/column_factories.hpp>
#include <cudf/column/column_view.hpp>
#include <cudf/copying.hpp>
#include <cudf/detail/interop.hpp>
#include <cudf/detail/iterator.cuh>
#include <cudf/detail/null_mask.hpp>
#include <cudf/detail/nvtx/ranges.hpp>
#include <cudf/detail/unary.hpp>
#include <cudf/dictionary/dictionary_column_view.hpp>
#include <cudf/interop.hpp>
#include <cudf/table/table_view.hpp>
#include <cudf/types.hpp>
#include <cudf/utilities/default_stream.hpp>
#include <cudf/utilities/traits.hpp>
#include <cudf/utilities/type_dispatcher.hpp>

#include <rmm/cuda_stream_view.hpp>
#include <rmm/exec_policy.hpp>
#include <rmm/mr/device/per_device_resource.hpp>

#include <thrust/copy.h>
#include <thrust/for_each.h>
#include <thrust/iterator/counting_iterator.h>

#include "detail/arrow_allocator.hpp"

namespace cudf {
namespace detail {
namespace {

/**
 * @brief Create arrow data buffer from given cudf column
 */
template <typename T>
std::shared_ptr<arrow::Buffer> fetch_data_buffer(column_view input_view,
                                                 arrow::MemoryPool* ar_mr,
                                                 rmm::cuda_stream_view stream)
{
  int64_t const data_size_in_bytes = sizeof(T) * input_view.size();

  auto data_buffer = allocate_arrow_buffer(data_size_in_bytes, ar_mr);

  CUDF_CUDA_TRY(cudaMemcpyAsync(data_buffer->mutable_data(),
                                input_view.data<T>(),
                                data_size_in_bytes,
                                cudaMemcpyDefault,
                                stream.value()));

  return std::move(data_buffer);
}

/**
 * @brief Create arrow buffer of mask from given cudf column
 */
std::shared_ptr<arrow::Buffer> fetch_mask_buffer(column_view input_view,
                                                 arrow::MemoryPool* ar_mr,
                                                 rmm::cuda_stream_view stream)
{
  int64_t const mask_size_in_bytes = cudf::bitmask_allocation_size_bytes(input_view.size());

  if (input_view.has_nulls()) {
    auto mask_buffer = allocate_arrow_bitmap(static_cast<int64_t>(input_view.size()), ar_mr);
    CUDF_CUDA_TRY(cudaMemcpyAsync(
      mask_buffer->mutable_data(),
      (input_view.offset() > 0)
        ? cudf::detail::copy_bitmask(input_view, stream, rmm::mr::get_current_device_resource())
            .data()
        : input_view.null_mask(),
      mask_size_in_bytes,
      cudaMemcpyDefault,
      stream.value()));

    // Resets all padded bits to 0
    mask_buffer->ZeroPadding();

    return mask_buffer;
  }

  return nullptr;
}

/**
 * @brief Functor to convert cudf column to arrow array
 */
struct dispatch_to_arrow {
  /**
   * @brief Creates vector Arrays from given cudf column children
   */
  std::vector<std::shared_ptr<arrow::Array>> fetch_child_array(
    column_view input_view,
    std::vector<column_metadata> const& metadata,
    arrow::MemoryPool* ar_mr,
    rmm::cuda_stream_view stream)
  {
    std::vector<std::shared_ptr<arrow::Array>> child_arrays;
    std::transform(
      input_view.child_begin(),
      input_view.child_end(),
      metadata.begin(),
      std::back_inserter(child_arrays),
      [&ar_mr, &stream](auto const& child, auto const& meta) {
        return type_dispatcher(
          child.type(), dispatch_to_arrow{}, child, child.type().id(), meta, ar_mr, stream);
      });
    return child_arrays;
  }

  template <typename T, CUDF_ENABLE_IF(not is_rep_layout_compatible<T>())>
  std::shared_ptr<arrow::Array> operator()(
    column_view, cudf::type_id, column_metadata const&, arrow::MemoryPool*, rmm::cuda_stream_view)
  {
    CUDF_FAIL("Unsupported type for to_arrow.");
  }

  template <typename T, CUDF_ENABLE_IF(is_rep_layout_compatible<T>())>
  std::shared_ptr<arrow::Array> operator()(column_view input_view,
                                           cudf::type_id id,
                                           column_metadata const&,
                                           arrow::MemoryPool* ar_mr,
                                           rmm::cuda_stream_view stream)
  {
    return to_arrow_array(id,
                          static_cast<int64_t>(input_view.size()),
                          fetch_data_buffer<T>(input_view, ar_mr, stream),
                          fetch_mask_buffer(input_view, ar_mr, stream),
                          static_cast<int64_t>(input_view.null_count()));
  }
};

// Convert decimal types from libcudf to arrow where those types are not
// directly supported by Arrow. These types must be fit into 128 bits, the
// smallest decimal resolution supported by Arrow.
template <typename DeviceType>
std::shared_ptr<arrow::Array> unsupported_decimals_to_arrow(column_view input,
                                                            int32_t precision,
                                                            arrow::MemoryPool* ar_mr,
                                                            rmm::cuda_stream_view stream)
{
  constexpr size_type BIT_WIDTH_RATIO = sizeof(__int128_t) / sizeof(DeviceType);

  rmm::device_uvector<DeviceType> buf(input.size() * BIT_WIDTH_RATIO, stream);

  auto count = thrust::make_counting_iterator(0);

  thrust::for_each(
    rmm::exec_policy(cudf::get_default_stream()),
    count,
    count + input.size(),
    [in = input.begin<DeviceType>(), out = buf.data(), BIT_WIDTH_RATIO] __device__(auto in_idx) {
      auto const out_idx = in_idx * BIT_WIDTH_RATIO;
      // The lowest order bits are the value, the remainder
      // simply matches the sign bit to satisfy the two's
      // complement integer representation of negative numbers.
      out[out_idx] = in[in_idx];
#pragma unroll BIT_WIDTH_RATIO - 1
      for (auto i = 1; i < BIT_WIDTH_RATIO; ++i) {
        out[out_idx + i] = in[in_idx] < 0 ? -1 : 0;
      }
    });

  auto const buf_size_in_bytes = buf.size() * sizeof(DeviceType);
  auto data_buffer             = allocate_arrow_buffer(buf_size_in_bytes, ar_mr);

  CUDF_CUDA_TRY(cudaMemcpyAsync(
    data_buffer->mutable_data(), buf.data(), buf_size_in_bytes, cudaMemcpyDefault, stream.value()));

  auto type    = arrow::decimal(precision, -input.type().scale());
  auto mask    = fetch_mask_buffer(input, ar_mr, stream);
  auto buffers = std::vector<std::shared_ptr<arrow::Buffer>>{mask, std::move(data_buffer)};
  auto data    = std::make_shared<arrow::ArrayData>(type, input.size(), buffers);

  return std::make_shared<arrow::Decimal128Array>(data);
}

template <>
std::shared_ptr<arrow::Array> dispatch_to_arrow::operator()<numeric::decimal32>(
  column_view input,
  cudf::type_id,
  column_metadata const&,
  arrow::MemoryPool* ar_mr,
  rmm::cuda_stream_view stream)
{
  return unsupported_decimals_to_arrow<int32_t>(input, 9, ar_mr, stream);
}

template <>
std::shared_ptr<arrow::Array> dispatch_to_arrow::operator()<numeric::decimal64>(
  column_view input,
  cudf::type_id,
  column_metadata const&,
  arrow::MemoryPool* ar_mr,
  rmm::cuda_stream_view stream)
{
  return unsupported_decimals_to_arrow<int64_t>(input, 18, ar_mr, stream);
}

template <>
std::shared_ptr<arrow::Array> dispatch_to_arrow::operator()<numeric::decimal128>(
  column_view input,
  cudf::type_id,
  column_metadata const&,
  arrow::MemoryPool* ar_mr,
  rmm::cuda_stream_view stream)
{
  using DeviceType = __int128_t;

  rmm::device_uvector<DeviceType> buf(input.size(), stream);

  thrust::copy(rmm::exec_policy(stream),  //
               input.begin<DeviceType>(),
               input.end<DeviceType>(),
               buf.begin());

  auto const buf_size_in_bytes = buf.size() * sizeof(DeviceType);
  auto data_buffer             = allocate_arrow_buffer(buf_size_in_bytes, ar_mr);

  CUDF_CUDA_TRY(cudaMemcpyAsync(
    data_buffer->mutable_data(), buf.data(), buf_size_in_bytes, cudaMemcpyDefault, stream.value()));

  auto type    = arrow::decimal(18, -input.type().scale());
  auto mask    = fetch_mask_buffer(input, ar_mr, stream);
  auto buffers = std::vector<std::shared_ptr<arrow::Buffer>>{mask, std::move(data_buffer)};
  auto data    = std::make_shared<arrow::ArrayData>(type, input.size(), buffers);

  return std::make_shared<arrow::Decimal128Array>(data);
}

template <>
std::shared_ptr<arrow::Array> dispatch_to_arrow::operator()<bool>(column_view input,
                                                                  cudf::type_id id,
                                                                  column_metadata const&,
                                                                  arrow::MemoryPool* ar_mr,
                                                                  rmm::cuda_stream_view stream)
{
  auto bitmask = bools_to_mask(input, stream, rmm::mr::get_current_device_resource());

  auto data_buffer = allocate_arrow_buffer(static_cast<int64_t>(bitmask.first->size()), ar_mr);

  CUDF_CUDA_TRY(cudaMemcpyAsync(data_buffer->mutable_data(),
                                bitmask.first->data(),
                                bitmask.first->size(),
                                cudaMemcpyDefault,
                                stream.value()));
  return to_arrow_array(id,
                        static_cast<int64_t>(input.size()),
                        std::move(data_buffer),
                        fetch_mask_buffer(input, ar_mr, stream),
                        static_cast<int64_t>(input.null_count()));
}

template <>
std::shared_ptr<arrow::Array> dispatch_to_arrow::operator()<cudf::string_view>(
  column_view input,
  cudf::type_id,
  column_metadata const&,
  arrow::MemoryPool* ar_mr,
  rmm::cuda_stream_view stream)
{
  std::unique_ptr<column> tmp_column =
    ((input.offset() != 0) or
     ((input.num_children() == 2) and (input.child(0).size() - 1 != input.size())))
      ? std::make_unique<cudf::column>(input, stream)
      : nullptr;

  column_view input_view = (tmp_column != nullptr) ? tmp_column->view() : input;
  auto child_arrays      = fetch_child_array(input_view, {{}, {}}, ar_mr, stream);
  if (child_arrays.empty()) {
    // Empty string will have only one value in offset of 4 bytes
    auto tmp_offset_buffer               = allocate_arrow_buffer(4, ar_mr);
    auto tmp_data_buffer                 = allocate_arrow_buffer(0, ar_mr);
    tmp_offset_buffer->mutable_data()[0] = 0;

    return std::make_shared<arrow::StringArray>(
      0, std::move(tmp_offset_buffer), std::move(tmp_data_buffer));
  }
  auto offset_buffer = child_arrays[0]->data()->buffers[1];
  auto data_buffer   = child_arrays[1]->data()->buffers[1];
  return std::make_shared<arrow::StringArray>(static_cast<int64_t>(input_view.size()),
                                              offset_buffer,
                                              data_buffer,
                                              fetch_mask_buffer(input_view, ar_mr, stream),
                                              static_cast<int64_t>(input_view.null_count()));
}

template <>
std::shared_ptr<arrow::Array> dispatch_to_arrow::operator()<cudf::struct_view>(
  column_view input,
  cudf::type_id,
  column_metadata const& metadata,
  arrow::MemoryPool* ar_mr,
  rmm::cuda_stream_view stream)
{
  CUDF_EXPECTS(metadata.children_meta.size() == static_cast<std::size_t>(input.num_children()),
               "Number of field names and number of children doesn't match\n");
  std::unique_ptr<column> tmp_column = nullptr;

  if (input.offset() != 0) { tmp_column = std::make_unique<cudf::column>(input, stream); }

  column_view input_view = (tmp_column != nullptr) ? tmp_column->view() : input;
  auto child_arrays      = fetch_child_array(input_view, metadata.children_meta, ar_mr, stream);
  auto mask              = fetch_mask_buffer(input_view, ar_mr, stream);

  std::vector<std::shared_ptr<arrow::Field>> fields;
  std::transform(child_arrays.cbegin(),
                 child_arrays.cend(),
                 metadata.children_meta.cbegin(),
                 std::back_inserter(fields),
                 [](auto const array, auto const meta) {
                   return std::make_shared<arrow::Field>(
                     meta.name, array->type(), array->null_count() > 0);
                 });
  auto dtype = std::make_shared<arrow::StructType>(fields);

  return std::make_shared<arrow::StructArray>(dtype,
                                              static_cast<int64_t>(input_view.size()),
                                              child_arrays,
                                              mask,
                                              static_cast<int64_t>(input_view.null_count()));
}

template <>
std::shared_ptr<arrow::Array> dispatch_to_arrow::operator()<cudf::list_view>(
  column_view input,
  cudf::type_id,
  column_metadata const& metadata,
  arrow::MemoryPool* ar_mr,
  rmm::cuda_stream_view stream)
{
  std::unique_ptr<column> tmp_column = nullptr;
  if ((input.offset() != 0) or
      ((input.num_children() == 2) and (input.child(0).size() - 1 != input.size()))) {
    tmp_column = std::make_unique<cudf::column>(input, stream);
  }

  column_view input_view = (tmp_column != nullptr) ? tmp_column->view() : input;
  auto children_meta =
    metadata.children_meta.empty() ? std::vector<column_metadata>{{}, {}} : metadata.children_meta;
  auto child_arrays = fetch_child_array(input_view, children_meta, ar_mr, stream);
  if (child_arrays.empty()) {
    return std::make_shared<arrow::ListArray>(arrow::list(arrow::null()), 0, nullptr, nullptr);
  }

  auto offset_buffer = child_arrays[0]->data()->buffers[1];
  auto data          = child_arrays[1];
  return std::make_shared<arrow::ListArray>(arrow::list(data->type()),
                                            static_cast<int64_t>(input_view.size()),
                                            offset_buffer,
                                            data,
                                            fetch_mask_buffer(input_view, ar_mr, stream),
                                            static_cast<int64_t>(input_view.null_count()));
}

template <>
std::shared_ptr<arrow::Array> dispatch_to_arrow::operator()<cudf::dictionary32>(
  column_view input,
  cudf::type_id,
  column_metadata const& metadata,
  arrow::MemoryPool* ar_mr,
  rmm::cuda_stream_view stream)
{
  // Arrow dictionary requires indices to be signed integer
  std::unique_ptr<column> dict_indices =
    cast(cudf::dictionary_column_view(input).get_indices_annotated(),
         cudf::data_type{type_id::INT32},
         stream,
         rmm::mr::get_current_device_resource());
  auto indices = dispatch_to_arrow{}.operator()<int32_t>(
    dict_indices->view(), dict_indices->type().id(), {}, ar_mr, stream);
  auto dict_keys = cudf::dictionary_column_view(input).keys();
  auto dictionary =
    type_dispatcher(dict_keys.type(),
                    dispatch_to_arrow{},
                    dict_keys,
                    dict_keys.type().id(),
                    metadata.children_meta.empty() ? column_metadata{} : metadata.children_meta[0],
                    ar_mr,
                    stream);

  return std::make_shared<arrow::DictionaryArray>(
    arrow::dictionary(indices->type(), dictionary->type()), indices, dictionary);
}
}  // namespace

std::shared_ptr<arrow::Table> to_arrow(table_view input,
                                       std::vector<column_metadata> const& metadata,
                                       rmm::cuda_stream_view stream,
                                       arrow::MemoryPool* ar_mr)
{
  CUDF_EXPECTS((metadata.size() == static_cast<std::size_t>(input.num_columns())),
               "columns' metadata should be equal to number of columns in table");

  std::vector<std::shared_ptr<arrow::Array>> arrays;
  std::vector<std::shared_ptr<arrow::Field>> fields;

  std::transform(
    input.begin(),
    input.end(),
    metadata.begin(),
    std::back_inserter(arrays),
    [&](auto const& c, auto const& meta) {
      return c.type().id() != type_id::EMPTY
               ? type_dispatcher(
                   c.type(), detail::dispatch_to_arrow{}, c, c.type().id(), meta, ar_mr, stream)
               : std::make_shared<arrow::NullArray>(c.size());
    });

  std::transform(
    arrays.begin(),
    arrays.end(),
    metadata.begin(),
    std::back_inserter(fields),
    [](auto const& array, auto const& meta) { return arrow::field(meta.name, array->type()); });

  auto result = arrow::Table::Make(arrow::schema(fields), arrays);

  // synchronize the stream because after the return the data may be accessed from the host before
  // the above `cudaMemcpyAsync` calls have completed their copies (especially if pinned host
  // memory is used).
  stream.synchronize();

  return result;
}

std::shared_ptr<arrow::Scalar> to_arrow(cudf::scalar const& input,
                                        column_metadata const& metadata,
                                        rmm::cuda_stream_view stream,
                                        arrow::MemoryPool* ar_mr)
{
  auto const column = cudf::make_column_from_scalar(input, 1, stream);
  cudf::table_view const tv{{column->view()}};
  auto const arrow_table  = cudf::to_arrow(tv, {metadata}, stream);
  auto const ac           = arrow_table->column(0);
  auto const maybe_scalar = ac->GetScalar(0);
  if (!maybe_scalar.ok()) { CUDF_FAIL("Failed to produce a scalar"); }
  return maybe_scalar.ValueOrDie();
}
}  // namespace detail

std::shared_ptr<arrow::Table> to_arrow(table_view input,
                                       std::vector<column_metadata> const& metadata,
                                       rmm::cuda_stream_view stream,
                                       arrow::MemoryPool* ar_mr)
{
  CUDF_FUNC_RANGE();
  return detail::to_arrow(input, metadata, stream, ar_mr);
}

std::shared_ptr<arrow::Scalar> to_arrow(cudf::scalar const& input,
                                        column_metadata const& metadata,
                                        rmm::cuda_stream_view stream,
                                        arrow::MemoryPool* ar_mr)
{
  CUDF_FUNC_RANGE();
  return detail::to_arrow(input, metadata, stream, ar_mr);
}
}  // namespace cudf
