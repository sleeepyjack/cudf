/*
 * Copyright (c) 2019-2023, NVIDIA CORPORATION.
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

#include <cudf/column/column_device_view.cuh>
#include <cudf/column/column_factories.hpp>
#include <cudf/detail/get_value.cuh>
#include <cudf/detail/null_mask.hpp>
#include <cudf/detail/nvtx/ranges.hpp>
#include <cudf/detail/utilities/cuda.cuh>
#include <cudf/strings/detail/char_tables.hpp>
#include <cudf/strings/detail/replace.hpp>
#include <cudf/strings/detail/strings_children.cuh>
#include <cudf/strings/detail/strings_column_factories.cuh>
#include <cudf/strings/detail/utilities.cuh>
#include <cudf/strings/replace.hpp>
#include <cudf/strings/string_view.cuh>
#include <cudf/strings/strings_column_view.hpp>
#include <cudf/utilities/default_stream.hpp>
#include <cudf/utilities/span.hpp>

#include <rmm/cuda_stream_view.hpp>
#include <rmm/device_uvector.hpp>

#include <thrust/binary_search.h>
#include <thrust/copy.h>
#include <thrust/count.h>
#include <thrust/distance.h>
#include <thrust/execution_policy.h>
#include <thrust/for_each.h>
#include <thrust/iterator/counting_iterator.h>
#include <thrust/optional.h>
#include <thrust/scan.h>
#include <thrust/transform.h>

namespace cudf {
namespace strings {
namespace detail {
namespace {

/**
 * @brief Threshold to decide on using string or character-parallel functions.
 *
 * If the average byte length of a string in a column exceeds this value then
 * the character-parallel function is used.
 * Otherwise, a regular string-parallel function is used.
 *
 * This value was found using the replace-multi benchmark results using an
 * RTX A6000.
 */
constexpr size_type AVG_CHAR_BYTES_THRESHOLD = 256;

/**
 * @brief Type used for holding the target position (first) and the
 * target index (second).
 */
using target_pair = thrust::pair<size_type, size_type>;

/**
 * @brief Helper functions for performing character-parallel replace
 */
struct replace_multi_parallel_fn {
  __device__ char const* get_base_ptr() const
  {
    return d_strings.child(strings_column_view::chars_column_index).data<char>();
  }

  __device__ size_type const* get_offsets_ptr() const
  {
    return d_strings.child(strings_column_view::offsets_column_index).data<size_type>() +
           d_strings.offset();
  }

  __device__ string_view const get_string(size_type idx) const
  {
    return d_strings.element<string_view>(idx);
  }

  __device__ string_view const get_replacement_string(size_type idx) const
  {
    return d_replacements.size() == 1 ? d_replacements[0] : d_replacements[idx];
  }

  __device__ bool is_valid(size_type idx) const { return d_strings.is_valid(idx); }

  /**
   * @brief Returns the index of the target string found at the given byte position
   * in the input strings column
   *
   * @param idx Index of the byte position in the chars column
   * @param chars_bytes Number of bytes in the chars column
   */
  __device__ thrust::optional<size_type> has_target(size_type idx, size_type chars_bytes) const
  {
    auto const d_offsets = get_offsets_ptr();
    auto const d_chars   = get_base_ptr() + d_offsets[0] + idx;
    size_type str_idx    = -1;
    for (std::size_t t = 0; t < d_targets.size(); ++t) {
      auto const d_tgt = d_targets[t];
      if (!d_tgt.empty() && (idx + d_tgt.size_bytes() <= chars_bytes) &&
          (d_tgt.compare(d_chars, d_tgt.size_bytes()) == 0)) {
        if (str_idx < 0) {
          auto const idx_itr =
            thrust::upper_bound(thrust::seq, d_offsets, d_offsets + d_strings.size(), idx);
          str_idx = thrust::distance(d_offsets, idx_itr) - 1;
        }
        auto const d_str = get_string(str_idx - d_offsets[0]);
        if ((d_chars + d_tgt.size_bytes()) <= (d_str.data() + d_str.size_bytes())) { return t; }
      }
    }
    return thrust::nullopt;
  }

  /**
   * @brief Count the number of strings that will be produced by the replace
   *
   * This includes segments of the string that are not replaced as well as those
   * that are replaced.
   *
   * @param idx Index of the row in d_strings to be processed
   * @param d_positions Positions of the targets found in the chars column
   * @param d_targets_offsets Offsets identify which target positions go with the current string
   * @return Number of substrings resulting from the replace operations on this row
   */
  __device__ size_type count_strings(size_type idx,
                                     target_pair const* d_positions,
                                     size_type const* d_targets_offsets) const
  {
    if (!is_valid(idx)) { return 0; }

    auto const d_str             = get_string(idx);
    auto const d_str_end         = d_str.data() + d_str.size_bytes();
    auto const base_ptr          = get_base_ptr();
    auto const targets_positions = cudf::device_span<target_pair const>(
      d_positions + d_targets_offsets[idx], d_targets_offsets[idx + 1] - d_targets_offsets[idx]);

    size_type count = 1;  // always at least one string
    auto str_ptr    = d_str.data();
    for (auto d_pair : targets_positions) {
      auto const d_pos   = d_pair.first;
      auto const d_tgt   = d_targets[d_pair.second];
      auto const tgt_ptr = base_ptr + d_pos;
      if (str_ptr <= tgt_ptr && tgt_ptr < d_str_end) {
        auto const keep_size = static_cast<size_type>(thrust::distance(str_ptr, tgt_ptr));
        if (keep_size > 0) { count++; }  // don't bother counting empty strings

        auto const d_repl = get_replacement_string(d_pair.second);
        if (!d_repl.empty()) { count++; }

        str_ptr += keep_size + d_tgt.size_bytes();
      }
    }

    return count;
  }

  /**
   * @brief Retrieve the strings for each row
   *
   * This will return string segments as string_index_pair objects for
   * parts of the string that are not replaced interlaced with the
   * appropriate replacement string where replacement targets are found.
   *
   * This function is called only once to produce both the string_index_pair objects
   * and the output row size in bytes.
   *
   * @param idx Index of the row in d_strings
   * @param d_offsets Offsets to identify where to store the results of the replace for this string
   * @param d_positions The target positions found in the chars column
   * @param d_targets_offsets The offsets to identify which target positions go with this string
   * @param d_all_strings The output of all the produced string segments
   * @return The size in bytes of the output string for this row
   */
  __device__ size_type get_strings(size_type idx,
                                   size_type const* d_offsets,
                                   target_pair const* d_positions,
                                   size_type const* d_targets_offsets,
                                   string_index_pair* d_all_strings) const
  {
    if (!is_valid(idx)) { return 0; }

    auto const d_output  = d_all_strings + d_offsets[idx];
    auto const d_str     = get_string(idx);
    auto const d_str_end = d_str.data() + d_str.size_bytes();
    auto const base_ptr  = get_base_ptr();

    auto const targets_positions = cudf::device_span<target_pair const>(
      d_positions + d_targets_offsets[idx], d_targets_offsets[idx + 1] - d_targets_offsets[idx]);

    size_type output_idx  = 0;
    size_type output_size = 0;
    auto str_ptr          = d_str.data();
    for (auto d_pair : targets_positions) {
      auto const d_pos   = d_pair.first;
      auto const d_tgt   = d_targets[d_pair.second];
      auto const tgt_ptr = base_ptr + d_pos;
      if (str_ptr <= tgt_ptr && tgt_ptr < d_str_end) {
        auto const keep_size = static_cast<size_type>(thrust::distance(str_ptr, tgt_ptr));
        if (keep_size > 0) { d_output[output_idx++] = string_index_pair{str_ptr, keep_size}; }
        output_size += keep_size;

        auto const d_repl = get_replacement_string(d_pair.second);
        if (!d_repl.empty()) {
          d_output[output_idx++] = string_index_pair{d_repl.data(), d_repl.size_bytes()};
        }
        output_size += d_repl.size_bytes();

        str_ptr += keep_size + d_tgt.size_bytes();
      }
    }
    // include any leftover parts of the string
    if (str_ptr <= d_str_end) {
      auto const left_size = static_cast<size_type>(thrust::distance(str_ptr, d_str_end));
      d_output[output_idx] = string_index_pair{str_ptr, left_size};
      output_size += left_size;
    }
    return output_size;
  }

  replace_multi_parallel_fn(column_device_view const& d_strings,
                            device_span<string_view const> d_targets,
                            device_span<string_view const> d_replacements)
    : d_strings(d_strings), d_targets{d_targets}, d_replacements{d_replacements}
  {
  }

 protected:
  column_device_view d_strings;
  device_span<string_view const> d_targets;
  device_span<string_view const> d_replacements;
};

/**
 * @brief Used by the copy-if function to produce target_pair objects
 *
 * Using an inplace lambda caused a runtime crash in thrust::copy_if
 * (this happens sometimes when passing device lambdas to thrust algorithms)
 */
struct pair_generator {
  __device__ target_pair operator()(int idx) const
  {
    auto pos = fn.has_target(idx, chars_bytes);
    return target_pair{idx, pos.value_or(-1)};
  }
  replace_multi_parallel_fn fn;
  size_type chars_bytes;
};

struct copy_if_fn {
  __device__ bool operator()(target_pair pos) { return pos.second >= 0; }
};

std::unique_ptr<column> replace_character_parallel(strings_column_view const& input,
                                                   strings_column_view const& targets,
                                                   strings_column_view const& repls,
                                                   rmm::cuda_stream_view stream,
                                                   rmm::mr::device_memory_resource* mr)
{
  auto d_strings = column_device_view::create(input.parent(), stream);

  auto const strings_count = input.size();
  auto const chars_bytes =
    cudf::detail::get_value<size_type>(input.offsets(), input.offset() + strings_count, stream) -
    cudf::detail::get_value<size_type>(input.offsets(), input.offset(), stream);

  auto d_targets =
    create_string_vector_from_column(targets, stream, rmm::mr::get_current_device_resource());
  auto d_replacements =
    create_string_vector_from_column(repls, stream, rmm::mr::get_current_device_resource());

  replace_multi_parallel_fn fn{*d_strings, d_targets, d_replacements};

  // count the number of targets in the entire column
  auto const target_count = thrust::count_if(rmm::exec_policy(stream),
                                             thrust::make_counting_iterator<size_type>(0),
                                             thrust::make_counting_iterator<size_type>(chars_bytes),
                                             [fn, chars_bytes] __device__(size_type idx) {
                                               return fn.has_target(idx, chars_bytes).has_value();
                                             });
  // Create a vector of every target position in the chars column.
  // These may include overlapping targets which will be resolved later.
  auto targets_positions = rmm::device_uvector<target_pair>(target_count, stream);
  auto d_positions       = targets_positions.data();

  auto const copy_itr =
    cudf::detail::make_counting_transform_iterator(0, pair_generator{fn, chars_bytes});
  auto const copy_end = thrust::copy_if(
    rmm::exec_policy(stream), copy_itr, copy_itr + chars_bytes, d_positions, copy_if_fn{});

  // create a vector of offsets to each string's set of target positions
  auto const targets_offsets = [&] {
    auto string_indices = rmm::device_uvector<size_type>(target_count, stream);

    auto const pos_itr = cudf::detail::make_counting_transform_iterator(
      0, [d_positions] __device__(auto idx) -> size_type { return d_positions[idx].first; });
    auto pos_count = std::distance(d_positions, copy_end);

    thrust::upper_bound(rmm::exec_policy(stream),
                        input.offsets_begin(),
                        input.offsets_end(),
                        pos_itr,
                        pos_itr + pos_count,
                        string_indices.begin());

    // compute offsets per string
    auto targets_offsets   = rmm::device_uvector<size_type>(strings_count + 1, stream);
    auto d_targets_offsets = targets_offsets.data();

    // memset to zero-out the target counts for any null-entries or strings with no targets
    thrust::uninitialized_fill(
      rmm::exec_policy(stream), targets_offsets.begin(), targets_offsets.end(), 0);

    // next, count the number of targets per string
    auto d_string_indices = string_indices.data();
    thrust::for_each_n(rmm::exec_policy(stream),
                       thrust::make_counting_iterator<size_type>(0),
                       target_count,
                       [d_string_indices, d_targets_offsets] __device__(size_type idx) {
                         auto const str_idx = d_string_indices[idx] - 1;
                         atomicAdd(d_targets_offsets + str_idx, 1);
                       });
    // finally, convert the counts into offsets
    thrust::exclusive_scan(rmm::exec_policy(stream),
                           targets_offsets.begin(),
                           targets_offsets.end(),
                           targets_offsets.begin());
    return targets_offsets;
  }();
  auto const d_targets_offsets = targets_offsets.data();

  // compute the number of string segments produced by replace in each string
  auto counts = rmm::device_uvector<size_type>(strings_count, stream);
  thrust::transform(rmm::exec_policy(stream),
                    thrust::make_counting_iterator<size_type>(0),
                    thrust::make_counting_iterator<size_type>(strings_count),
                    counts.begin(),
                    [fn, d_positions, d_targets_offsets] __device__(size_type idx) -> size_type {
                      return fn.count_strings(idx, d_positions, d_targets_offsets);
                    });

  // create offsets from the counts
  auto offsets =
    std::get<0>(cudf::detail::make_offsets_child_column(counts.begin(), counts.end(), stream, mr));
  auto const total_strings =
    cudf::detail::get_value<size_type>(offsets->view(), strings_count, stream);
  auto const d_strings_offsets = offsets->view().data<size_type>();

  // build a vector of all the positions for all the strings
  auto indices   = rmm::device_uvector<string_index_pair>(total_strings, stream);
  auto d_indices = indices.data();
  auto d_sizes   = counts.data();  // reusing this vector to hold output sizes now
  thrust::for_each_n(
    rmm::exec_policy(stream),
    thrust::make_counting_iterator<size_type>(0),
    strings_count,
    [fn, d_strings_offsets, d_positions, d_targets_offsets, d_indices, d_sizes] __device__(
      size_type idx) {
      d_sizes[idx] =
        fn.get_strings(idx, d_strings_offsets, d_positions, d_targets_offsets, d_indices);
    });

  // use this utility to gather the string parts into a contiguous chars column
  auto chars = make_strings_column(indices.begin(), indices.end(), stream, mr);

  // create offsets from the sizes
  offsets =
    std::get<0>(cudf::detail::make_offsets_child_column(counts.begin(), counts.end(), stream, mr));

  // build the strings columns from the chars and offsets
  return make_strings_column(strings_count,
                             std::move(offsets),
                             std::move(chars->release().children.back()),
                             input.null_count(),
                             copy_bitmask(input.parent(), stream, mr));
}

/**
 * @brief Function logic for the replace_string_parallel
 *
 * Performs the multi-replace operation with a thread per string.
 * This performs best on smaller strings. @see AVG_CHAR_BYTES_THRESHOLD
 */
struct replace_multi_fn {
  column_device_view const d_strings;
  column_device_view const d_targets;
  column_device_view const d_repls;
  int32_t* d_offsets{};
  char* d_chars{};

  __device__ void operator()(size_type idx)
  {
    if (d_strings.is_null(idx)) {
      if (!d_chars) { d_offsets[idx] = 0; }
      return;
    }
    auto const d_str   = d_strings.element<string_view>(idx);
    char const* in_ptr = d_str.data();

    size_type bytes = d_str.size_bytes();
    size_type spos  = 0;
    size_type lpos  = 0;
    char* out_ptr   = d_chars ? d_chars + d_offsets[idx] : nullptr;

    // check each character against each target
    while (spos < d_str.size_bytes()) {
      for (int tgt_idx = 0; tgt_idx < d_targets.size(); ++tgt_idx) {
        auto const d_tgt = d_targets.element<string_view>(tgt_idx);
        if ((d_tgt.size_bytes() <= (d_str.size_bytes() - spos)) &&    // check fit
            (d_tgt.compare(in_ptr + spos, d_tgt.size_bytes()) == 0))  // and match
        {
          auto const d_repl = (d_repls.size() == 1) ? d_repls.element<string_view>(0)
                                                    : d_repls.element<string_view>(tgt_idx);
          bytes += d_repl.size_bytes() - d_tgt.size_bytes();
          if (out_ptr) {
            out_ptr = copy_and_increment(out_ptr, in_ptr + lpos, spos - lpos);
            out_ptr = copy_string(out_ptr, d_repl);
            lpos    = spos + d_tgt.size_bytes();
          }
          spos += d_tgt.size_bytes() - 1;
          break;
        }
      }
      ++spos;
    }
    if (out_ptr)  // copy remainder
      memcpy(out_ptr, in_ptr + lpos, d_str.size_bytes() - lpos);
    else
      d_offsets[idx] = bytes;
  }
};

std::unique_ptr<column> replace_string_parallel(strings_column_view const& input,
                                                strings_column_view const& targets,
                                                strings_column_view const& repls,
                                                rmm::cuda_stream_view stream,
                                                rmm::mr::device_memory_resource* mr)
{
  auto d_strings      = column_device_view::create(input.parent(), stream);
  auto d_targets      = column_device_view::create(targets.parent(), stream);
  auto d_replacements = column_device_view::create(repls.parent(), stream);

  auto children = cudf::strings::detail::make_strings_children(
    replace_multi_fn{*d_strings, *d_targets, *d_replacements}, input.size(), stream, mr);

  return make_strings_column(input.size(),
                             std::move(children.first),
                             std::move(children.second),
                             input.null_count(),
                             cudf::detail::copy_bitmask(input.parent(), stream, mr));
}

}  // namespace

std::unique_ptr<column> replace(strings_column_view const& input,
                                strings_column_view const& targets,
                                strings_column_view const& repls,
                                rmm::cuda_stream_view stream,
                                rmm::mr::device_memory_resource* mr)
{
  if (input.is_empty()) { return make_empty_column(type_id::STRING); }
  CUDF_EXPECTS(((targets.size() > 0) && (targets.null_count() == 0)),
               "Parameters targets must not be empty and must not have nulls");
  CUDF_EXPECTS(((repls.size() > 0) && (repls.null_count() == 0)),
               "Parameters repls must not be empty and must not have nulls");
  if (repls.size() > 1)
    CUDF_EXPECTS(repls.size() == targets.size(), "Sizes for targets and repls must match");

  return (input.size() == input.null_count() ||
          ((input.chars_size() / (input.size() - input.null_count())) < AVG_CHAR_BYTES_THRESHOLD))
           ? replace_string_parallel(input, targets, repls, stream, mr)
           : replace_character_parallel(input, targets, repls, stream, mr);
}

}  // namespace detail

// external API

std::unique_ptr<column> replace(strings_column_view const& strings,
                                strings_column_view const& targets,
                                strings_column_view const& repls,
                                rmm::cuda_stream_view stream,
                                rmm::mr::device_memory_resource* mr)
{
  CUDF_FUNC_RANGE();
  return detail::replace(strings, targets, repls, stream, mr);
}

}  // namespace strings
}  // namespace cudf
