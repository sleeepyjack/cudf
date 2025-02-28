/*
 * Copyright (c) 2022-2023, NVIDIA CORPORATION.
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

#include "reader_impl.hpp"

#include <io/comp/nvcomp_adapter.hpp>
#include <io/utilities/config_utils.hpp>

#include <cudf/detail/iterator.cuh>
#include <cudf/detail/utilities/integer_utils.hpp>
#include <cudf/detail/utilities/vector_factories.hpp>

#include <rmm/exec_policy.hpp>

#include <thrust/binary_search.h>
#include <thrust/fill.h>
#include <thrust/functional.h>
#include <thrust/iterator/constant_iterator.h>
#include <thrust/iterator/discard_iterator.h>
#include <thrust/iterator/iterator_categories.h>
#include <thrust/iterator/transform_iterator.h>
#include <thrust/logical.h>
#include <thrust/reduce.h>
#include <thrust/scan.h>
#include <thrust/sequence.h>
#include <thrust/sort.h>
#include <thrust/transform.h>
#include <thrust/unique.h>

#include <numeric>

namespace cudf::io::parquet::detail {
namespace {

/**
 * @brief Generate depth remappings for repetition and definition levels.
 *
 * When dealing with columns that contain lists, we must examine incoming
 * repetition and definition level pairs to determine what range of output nesting
 * is indicated when adding new values.  This function generates the mappings of
 * the R/D levels to those start/end bounds
 *
 * @param remap Maps column schema index to the R/D remapping vectors for that column
 * @param src_col_schema The column schema to generate the new mapping for
 * @param md File metadata information
 */
void generate_depth_remappings(std::map<int, std::pair<std::vector<int>, std::vector<int>>>& remap,
                               int src_col_schema,
                               aggregate_reader_metadata const& md)
{
  // already generated for this level
  if (remap.find(src_col_schema) != remap.end()) { return; }
  auto schema   = md.get_schema(src_col_schema);
  int max_depth = md.get_output_nesting_depth(src_col_schema);

  CUDF_EXPECTS(remap.find(src_col_schema) == remap.end(),
               "Attempting to remap a schema more than once");
  auto inserted =
    remap.insert(std::pair<int, std::pair<std::vector<int>, std::vector<int>>>{src_col_schema, {}});
  auto& depth_remap = inserted.first->second;

  std::vector<int>& rep_depth_remap = (depth_remap.first);
  rep_depth_remap.resize(schema.max_repetition_level + 1);
  std::vector<int>& def_depth_remap = (depth_remap.second);
  def_depth_remap.resize(schema.max_definition_level + 1);

  // the key:
  // for incoming level values  R/D
  // add values starting at the shallowest nesting level X has repetition level R
  // until you reach the deepest nesting level Y that corresponds to the repetition level R1
  // held by the nesting level that has definition level D
  //
  // Example: a 3 level struct with a list at the bottom
  //
  //                     R / D   Depth
  // level0              0 / 1     0
  //   level1            0 / 2     1
  //     level2          0 / 3     2
  //       list          0 / 3     3
  //         element     1 / 4     4
  //
  // incoming R/D : 0, 0  -> add values from depth 0 to 3   (def level 0 always maps to depth 0)
  // incoming R/D : 0, 1  -> add values from depth 0 to 3
  // incoming R/D : 0, 2  -> add values from depth 0 to 3
  // incoming R/D : 1, 4  -> add values from depth 4 to 4
  //
  // Note : the -validity- of values is simply checked by comparing the incoming D value against the
  // D value of the given nesting level (incoming D >= the D for the nesting level == valid,
  // otherwise NULL).  The tricky part is determining what nesting levels to add values at.
  //
  // For schemas with no repetition level (no lists), X is always 0 and Y is always max nesting
  // depth.
  //

  // compute "X" from above
  for (int s_idx = schema.max_repetition_level; s_idx >= 0; s_idx--) {
    auto find_shallowest = [&](int r) {
      int shallowest = -1;
      int cur_depth  = max_depth - 1;
      int schema_idx = src_col_schema;
      while (schema_idx > 0) {
        auto cur_schema = md.get_schema(schema_idx);
        if (cur_schema.max_repetition_level == r) {
          // if this is a repeated field, map it one level deeper
          shallowest = cur_schema.is_stub() ? cur_depth + 1 : cur_depth;
        }
        // if it's one-level encoding list
        else if (cur_schema.is_one_level_list(md.get_schema(cur_schema.parent_idx))) {
          shallowest = cur_depth - 1;
        }
        if (!cur_schema.is_stub()) { cur_depth--; }
        schema_idx = cur_schema.parent_idx;
      }
      return shallowest;
    };
    rep_depth_remap[s_idx] = find_shallowest(s_idx);
  }

  // compute "Y" from above
  for (int s_idx = schema.max_definition_level; s_idx >= 0; s_idx--) {
    auto find_deepest = [&](int d) {
      SchemaElement prev_schema;
      int schema_idx = src_col_schema;
      int r1         = 0;
      while (schema_idx > 0) {
        SchemaElement cur_schema = md.get_schema(schema_idx);
        if (cur_schema.max_definition_level == d) {
          // if this is a repeated field, map it one level deeper
          r1 = cur_schema.is_stub() ? prev_schema.max_repetition_level
                                    : cur_schema.max_repetition_level;
          break;
        }
        prev_schema = cur_schema;
        schema_idx  = cur_schema.parent_idx;
      }

      // we now know R1 from above. return the deepest nesting level that has the
      // same repetition level
      schema_idx = src_col_schema;
      int depth  = max_depth - 1;
      while (schema_idx > 0) {
        SchemaElement cur_schema = md.get_schema(schema_idx);
        if (cur_schema.max_repetition_level == r1) {
          // if this is a repeated field, map it one level deeper
          depth = cur_schema.is_stub() ? depth + 1 : depth;
          break;
        }
        if (!cur_schema.is_stub()) { depth--; }
        prev_schema = cur_schema;
        schema_idx  = cur_schema.parent_idx;
      }
      return depth;
    };
    def_depth_remap[s_idx] = find_deepest(s_idx);
  }
}

/**
 * @brief Reads compressed page data to device memory.
 *
 * @param sources Dataset sources
 * @param page_data Buffers to hold compressed page data for each chunk
 * @param chunks List of column chunk descriptors
 * @param begin_chunk Index of first column chunk to read
 * @param end_chunk Index after the last column chunk to read
 * @param column_chunk_offsets File offset for all chunks
 * @param chunk_source_map Association between each column chunk and its source
 * @param stream CUDA stream used for device memory operations and kernel launches
 *
 * @return A future object for reading synchronization
 */
[[nodiscard]] std::future<void> read_column_chunks_async(
  std::vector<std::unique_ptr<datasource>> const& sources,
  std::vector<std::unique_ptr<datasource::buffer>>& page_data,
  cudf::detail::hostdevice_vector<ColumnChunkDesc>& chunks,
  size_t begin_chunk,
  size_t end_chunk,
  std::vector<size_t> const& column_chunk_offsets,
  std::vector<size_type> const& chunk_source_map,
  rmm::cuda_stream_view stream)
{
  // Transfer chunk data, coalescing adjacent chunks
  std::vector<std::future<size_t>> read_tasks;
  for (size_t chunk = begin_chunk; chunk < end_chunk;) {
    size_t const io_offset   = column_chunk_offsets[chunk];
    size_t io_size           = chunks[chunk].compressed_size;
    size_t next_chunk        = chunk + 1;
    bool const is_compressed = (chunks[chunk].codec != Compression::UNCOMPRESSED);
    while (next_chunk < end_chunk) {
      size_t const next_offset      = column_chunk_offsets[next_chunk];
      bool const is_next_compressed = (chunks[next_chunk].codec != Compression::UNCOMPRESSED);
      if (next_offset != io_offset + io_size || is_next_compressed != is_compressed ||
          chunk_source_map[chunk] != chunk_source_map[next_chunk]) {
        // Can't merge if not contiguous or mixing compressed and uncompressed
        // Not coalescing uncompressed with compressed chunks is so that compressed buffers can be
        // freed earlier (immediately after decompression stage) to limit peak memory requirements
        break;
      }
      io_size += chunks[next_chunk].compressed_size;
      next_chunk++;
    }
    if (io_size != 0) {
      auto& source = sources[chunk_source_map[chunk]];
      if (source->is_device_read_preferred(io_size)) {
        // Buffer needs to be padded.
        // Required by `gpuDecodePageData`.
        auto buffer =
          rmm::device_buffer(cudf::util::round_up_safe(io_size, BUFFER_PADDING_MULTIPLE), stream);
        auto fut_read_size = source->device_read_async(
          io_offset, io_size, static_cast<uint8_t*>(buffer.data()), stream);
        read_tasks.emplace_back(std::move(fut_read_size));
        page_data[chunk] = datasource::buffer::create(std::move(buffer));
      } else {
        auto const read_buffer = source->host_read(io_offset, io_size);
        // Buffer needs to be padded.
        // Required by `gpuDecodePageData`.
        auto tmp_buffer = rmm::device_buffer(
          cudf::util::round_up_safe(read_buffer->size(), BUFFER_PADDING_MULTIPLE), stream);
        CUDF_CUDA_TRY(cudaMemcpyAsync(
          tmp_buffer.data(), read_buffer->data(), read_buffer->size(), cudaMemcpyDefault, stream));
        page_data[chunk] = datasource::buffer::create(std::move(tmp_buffer));
      }
      auto d_compdata = page_data[chunk]->data();
      do {
        chunks[chunk].compressed_data = d_compdata;
        d_compdata += chunks[chunk].compressed_size;
      } while (++chunk != next_chunk);
    } else {
      chunk = next_chunk;
    }
  }
  auto sync_fn = [](decltype(read_tasks) read_tasks) {
    for (auto& task : read_tasks) {
      task.wait();
    }
  };
  return std::async(std::launch::deferred, sync_fn, std::move(read_tasks));
}

/**
 * @brief Return the number of total pages from the given column chunks.
 *
 * @param chunks List of column chunk descriptors
 * @param stream CUDA stream used for device memory operations and kernel launches
 *
 * @return The total number of pages
 */
[[nodiscard]] size_t count_page_headers(cudf::detail::hostdevice_vector<ColumnChunkDesc>& chunks,
                                        rmm::cuda_stream_view stream)
{
  size_t total_pages = 0;

  chunks.host_to_device_async(stream);
  DecodePageHeaders(chunks.device_ptr(), chunks.size(), stream);
  chunks.device_to_host_sync(stream);

  for (size_t c = 0; c < chunks.size(); c++) {
    total_pages += chunks[c].num_data_pages + chunks[c].num_dict_pages;
  }

  return total_pages;
}

// see setupLocalPageInfo() in page_data.cu for supported page encodings
constexpr bool is_supported_encoding(Encoding enc)
{
  switch (enc) {
    case Encoding::PLAIN:
    case Encoding::PLAIN_DICTIONARY:
    case Encoding::RLE:
    case Encoding::RLE_DICTIONARY:
    case Encoding::DELTA_BINARY_PACKED: return true;
    default: return false;
  }
}

/**
 * @brief Decode the page information from the given column chunks.
 *
 * @param chunks List of column chunk descriptors
 * @param pages List of page information
 * @param stream CUDA stream used for device memory operations and kernel launches
 * @returns The size in bytes of level type data required
 */
int decode_page_headers(cudf::detail::hostdevice_vector<ColumnChunkDesc>& chunks,
                        cudf::detail::hostdevice_vector<PageInfo>& pages,
                        rmm::cuda_stream_view stream)
{
  // IMPORTANT : if you change how pages are stored within a chunk (dist pages, then data pages),
  // please update preprocess_nested_columns to reflect this.
  for (size_t c = 0, page_count = 0; c < chunks.size(); c++) {
    chunks[c].max_num_pages = chunks[c].num_data_pages + chunks[c].num_dict_pages;
    chunks[c].page_info     = pages.device_ptr(page_count);
    page_count += chunks[c].max_num_pages;
  }

  chunks.host_to_device_async(stream);
  DecodePageHeaders(chunks.device_ptr(), chunks.size(), stream);

  // compute max bytes needed for level data
  auto level_bit_size =
    cudf::detail::make_counting_transform_iterator(0, [chunks = chunks.begin()] __device__(int i) {
      auto c = chunks[i];
      return static_cast<int>(
        max(c.level_bits[level_type::REPETITION], c.level_bits[level_type::DEFINITION]));
    });
  // max level data bit size.
  int const max_level_bits   = thrust::reduce(rmm::exec_policy(stream),
                                            level_bit_size,
                                            level_bit_size + chunks.size(),
                                            0,
                                            thrust::maximum<int>());
  auto const level_type_size = std::max(1, cudf::util::div_rounding_up_safe(max_level_bits, 8));

  pages.device_to_host_sync(stream);

  // validate page encodings
  CUDF_EXPECTS(std::all_of(pages.begin(),
                           pages.end(),
                           [](auto const& page) { return is_supported_encoding(page.encoding); }),
               "Unsupported page encoding detected");

  return level_type_size;
}

/**
 * @brief Decompresses the page data, at page granularity.
 *
 * @param chunks List of column chunk descriptors
 * @param pages List of page information
 * @param stream CUDA stream used for device memory operations and kernel launches
 *
 * @return Device buffer to decompressed page data
 */
[[nodiscard]] rmm::device_buffer decompress_page_data(
  cudf::detail::hostdevice_vector<ColumnChunkDesc>& chunks,
  cudf::detail::hostdevice_vector<PageInfo>& pages,
  rmm::cuda_stream_view stream)
{
  auto for_each_codec_page = [&](Compression codec, std::function<void(size_t)> const& f) {
    for (size_t c = 0, page_count = 0; c < chunks.size(); c++) {
      const auto page_stride = chunks[c].max_num_pages;
      if (chunks[c].codec == codec) {
        for (int k = 0; k < page_stride; k++) {
          f(page_count + k);
        }
      }
      page_count += page_stride;
    }
  };

  // Brotli scratch memory for decompressing
  rmm::device_buffer debrotli_scratch;

  // Count the exact number of compressed pages
  size_t num_comp_pages    = 0;
  size_t total_decomp_size = 0;

  struct codec_stats {
    Compression compression_type  = UNCOMPRESSED;
    size_t num_pages              = 0;
    int32_t max_decompressed_size = 0;
    size_t total_decomp_size      = 0;
  };

  std::array codecs{codec_stats{GZIP}, codec_stats{SNAPPY}, codec_stats{BROTLI}, codec_stats{ZSTD}};

  auto is_codec_supported = [&codecs](int8_t codec) {
    if (codec == UNCOMPRESSED) return true;
    return std::find_if(codecs.begin(), codecs.end(), [codec](auto& cstats) {
             return codec == cstats.compression_type;
           }) != codecs.end();
  };
  CUDF_EXPECTS(std::all_of(chunks.begin(),
                           chunks.end(),
                           [&is_codec_supported](auto const& chunk) {
                             return is_codec_supported(chunk.codec);
                           }),
               "Unsupported compression type");

  for (auto& codec : codecs) {
    for_each_codec_page(codec.compression_type, [&](size_t page) {
      auto page_uncomp_size = pages[page].uncompressed_page_size;
      total_decomp_size += page_uncomp_size;
      codec.total_decomp_size += page_uncomp_size;
      codec.max_decompressed_size = std::max(codec.max_decompressed_size, page_uncomp_size);
      codec.num_pages++;
      num_comp_pages++;
    });
    if (codec.compression_type == BROTLI && codec.num_pages > 0) {
      debrotli_scratch.resize(get_gpu_debrotli_scratch_size(codec.num_pages), stream);
    }
  }

  // Dispatch batches of pages to decompress for each codec.
  // Buffer needs to be padded, required by `gpuDecodePageData`.
  rmm::device_buffer decomp_pages(
    cudf::util::round_up_safe(total_decomp_size, BUFFER_PADDING_MULTIPLE), stream);

  std::vector<device_span<uint8_t const>> comp_in;
  comp_in.reserve(num_comp_pages);
  std::vector<device_span<uint8_t>> comp_out;
  comp_out.reserve(num_comp_pages);

  // vectors to save v2 def and rep level data, if any
  std::vector<device_span<uint8_t const>> copy_in;
  copy_in.reserve(num_comp_pages);
  std::vector<device_span<uint8_t>> copy_out;
  copy_out.reserve(num_comp_pages);

  rmm::device_uvector<compression_result> comp_res(num_comp_pages, stream);
  thrust::fill(rmm::exec_policy(stream),
               comp_res.begin(),
               comp_res.end(),
               compression_result{0, compression_status::FAILURE});

  size_t decomp_offset = 0;
  int32_t start_pos    = 0;
  for (auto const& codec : codecs) {
    if (codec.num_pages == 0) { continue; }

    for_each_codec_page(codec.compression_type, [&](size_t page_idx) {
      auto const dst_base = static_cast<uint8_t*>(decomp_pages.data()) + decomp_offset;
      auto& page          = pages[page_idx];
      // offset will only be non-zero for V2 pages
      auto const offset =
        page.lvl_bytes[level_type::DEFINITION] + page.lvl_bytes[level_type::REPETITION];
      // for V2 need to copy def and rep level info into place, and then offset the
      // input and output buffers. otherwise we'd have to keep both the compressed
      // and decompressed data.
      if (offset != 0) {
        copy_in.emplace_back(page.page_data, offset);
        copy_out.emplace_back(dst_base, offset);
      }
      comp_in.emplace_back(page.page_data + offset,
                           static_cast<size_t>(page.compressed_page_size - offset));
      comp_out.emplace_back(dst_base + offset,
                            static_cast<size_t>(page.uncompressed_page_size - offset));
      page.page_data = dst_base;
      decomp_offset += page.uncompressed_page_size;
    });

    host_span<device_span<uint8_t const> const> comp_in_view{comp_in.data() + start_pos,
                                                             codec.num_pages};
    auto const d_comp_in = cudf::detail::make_device_uvector_async(
      comp_in_view, stream, rmm::mr::get_current_device_resource());
    host_span<device_span<uint8_t> const> comp_out_view(comp_out.data() + start_pos,
                                                        codec.num_pages);
    auto const d_comp_out = cudf::detail::make_device_uvector_async(
      comp_out_view, stream, rmm::mr::get_current_device_resource());
    device_span<compression_result> d_comp_res_view(comp_res.data() + start_pos, codec.num_pages);

    switch (codec.compression_type) {
      case GZIP:
        gpuinflate(d_comp_in, d_comp_out, d_comp_res_view, gzip_header_included::YES, stream);
        break;
      case SNAPPY:
        if (cudf::io::detail::nvcomp_integration::is_stable_enabled()) {
          nvcomp::batched_decompress(nvcomp::compression_type::SNAPPY,
                                     d_comp_in,
                                     d_comp_out,
                                     d_comp_res_view,
                                     codec.max_decompressed_size,
                                     codec.total_decomp_size,
                                     stream);
        } else {
          gpu_unsnap(d_comp_in, d_comp_out, d_comp_res_view, stream);
        }
        break;
      case ZSTD:
        nvcomp::batched_decompress(nvcomp::compression_type::ZSTD,
                                   d_comp_in,
                                   d_comp_out,
                                   d_comp_res_view,
                                   codec.max_decompressed_size,
                                   codec.total_decomp_size,
                                   stream);
        break;
      case BROTLI:
        gpu_debrotli(d_comp_in,
                     d_comp_out,
                     d_comp_res_view,
                     debrotli_scratch.data(),
                     debrotli_scratch.size(),
                     stream);
        break;
      default: CUDF_FAIL("Unexpected decompression dispatch"); break;
    }
    start_pos += codec.num_pages;
  }

  CUDF_EXPECTS(thrust::all_of(rmm::exec_policy(stream),
                              comp_res.begin(),
                              comp_res.end(),
                              [] __device__(auto const& res) {
                                return res.status == compression_status::SUCCESS;
                              }),
               "Error during decompression");

  // now copy the uncompressed V2 def and rep level data
  if (not copy_in.empty()) {
    auto const d_copy_in = cudf::detail::make_device_uvector_async(
      copy_in, stream, rmm::mr::get_current_device_resource());
    auto const d_copy_out = cudf::detail::make_device_uvector_async(
      copy_out, stream, rmm::mr::get_current_device_resource());

    gpu_copy_uncompressed_blocks(d_copy_in, d_copy_out, stream);
    stream.synchronize();
  }

  // Update the page information in device memory with the updated value of
  // page_data; it now points to the uncompressed data buffer
  pages.host_to_device_async(stream);

  return decomp_pages;
}

}  // namespace

void reader::impl::allocate_nesting_info()
{
  auto const& chunks             = _pass_itm_data->chunks;
  auto& pages                    = _pass_itm_data->pages_info;
  auto& page_nesting_info        = _pass_itm_data->page_nesting_info;
  auto& page_nesting_decode_info = _pass_itm_data->page_nesting_decode_info;

  // compute total # of page_nesting infos needed and allocate space. doing this in one
  // buffer to keep it to a single gpu allocation
  size_t const total_page_nesting_infos = std::accumulate(
    chunks.host_ptr(), chunks.host_ptr() + chunks.size(), 0, [&](int total, auto& chunk) {
      // the schema of the input column
      auto const& schema                    = _metadata->get_schema(chunk.src_col_schema);
      auto const per_page_nesting_info_size = max(
        schema.max_definition_level + 1, _metadata->get_output_nesting_depth(chunk.src_col_schema));
      return total + (per_page_nesting_info_size * chunk.num_data_pages);
    });

  page_nesting_info =
    cudf::detail::hostdevice_vector<PageNestingInfo>{total_page_nesting_infos, _stream};
  page_nesting_decode_info =
    cudf::detail::hostdevice_vector<PageNestingDecodeInfo>{total_page_nesting_infos, _stream};

  // update pointers in the PageInfos
  int target_page_index = 0;
  int src_info_index    = 0;
  for (size_t idx = 0; idx < chunks.size(); idx++) {
    int src_col_schema                    = chunks[idx].src_col_schema;
    auto& schema                          = _metadata->get_schema(src_col_schema);
    auto const per_page_nesting_info_size = std::max(
      schema.max_definition_level + 1, _metadata->get_output_nesting_depth(src_col_schema));

    // skip my dict pages
    target_page_index += chunks[idx].num_dict_pages;
    for (int p_idx = 0; p_idx < chunks[idx].num_data_pages; p_idx++) {
      pages[target_page_index + p_idx].nesting = page_nesting_info.device_ptr() + src_info_index;
      pages[target_page_index + p_idx].nesting_decode =
        page_nesting_decode_info.device_ptr() + src_info_index;

      pages[target_page_index + p_idx].nesting_info_size = per_page_nesting_info_size;
      pages[target_page_index + p_idx].num_output_nesting_levels =
        _metadata->get_output_nesting_depth(src_col_schema);

      src_info_index += per_page_nesting_info_size;
    }
    target_page_index += chunks[idx].num_data_pages;
  }

  // fill in
  int nesting_info_index = 0;
  std::map<int, std::pair<std::vector<int>, std::vector<int>>> depth_remapping;
  for (size_t idx = 0; idx < chunks.size(); idx++) {
    int src_col_schema = chunks[idx].src_col_schema;

    // schema of the input column
    auto& schema = _metadata->get_schema(src_col_schema);
    // real depth of the output cudf column hierarchy (1 == no nesting, 2 == 1 level, etc)
    int max_depth = _metadata->get_output_nesting_depth(src_col_schema);

    // # of nesting infos stored per page for this column
    auto const per_page_nesting_info_size = std::max(schema.max_definition_level + 1, max_depth);

    // if this column has lists, generate depth remapping
    std::map<int, std::pair<std::vector<int>, std::vector<int>>> depth_remapping;
    if (schema.max_repetition_level > 0) {
      generate_depth_remappings(depth_remapping, src_col_schema, *_metadata);
    }

    // fill in host-side nesting info
    int schema_idx  = src_col_schema;
    auto cur_schema = _metadata->get_schema(schema_idx);
    int cur_depth   = max_depth - 1;
    while (schema_idx > 0) {
      // stub columns (basically the inner field of a list scheme element) are not real columns.
      // we can ignore them for the purposes of output nesting info
      if (!cur_schema.is_stub()) {
        // initialize each page within the chunk
        for (int p_idx = 0; p_idx < chunks[idx].num_data_pages; p_idx++) {
          PageNestingInfo* pni =
            &page_nesting_info[nesting_info_index + (p_idx * per_page_nesting_info_size)];

          PageNestingDecodeInfo* nesting_info =
            &page_nesting_decode_info[nesting_info_index + (p_idx * per_page_nesting_info_size)];

          // if we have lists, set our start and end depth remappings
          if (schema.max_repetition_level > 0) {
            auto remap = depth_remapping.find(src_col_schema);
            CUDF_EXPECTS(remap != depth_remapping.end(),
                         "Could not find depth remapping for schema");
            std::vector<int> const& rep_depth_remap = (remap->second.first);
            std::vector<int> const& def_depth_remap = (remap->second.second);

            for (size_t m = 0; m < rep_depth_remap.size(); m++) {
              nesting_info[m].start_depth = rep_depth_remap[m];
            }
            for (size_t m = 0; m < def_depth_remap.size(); m++) {
              nesting_info[m].end_depth = def_depth_remap[m];
            }
          }

          // values indexed by output column index
          nesting_info[cur_depth].max_def_level = cur_schema.max_definition_level;
          pni[cur_depth].size                   = 0;
          pni[cur_depth].type =
            to_type_id(cur_schema, _strings_to_categorical, _timestamp_type.id());
          pni[cur_depth].nullable = cur_schema.repetition_type == OPTIONAL;
        }

        // move up the hierarchy
        cur_depth--;
      }

      // next schema
      schema_idx = cur_schema.parent_idx;
      cur_schema = _metadata->get_schema(schema_idx);
    }

    nesting_info_index += (per_page_nesting_info_size * chunks[idx].num_data_pages);
  }

  // copy nesting info to the device
  page_nesting_info.host_to_device_async(_stream);
  page_nesting_decode_info.host_to_device_async(_stream);
}

void reader::impl::allocate_level_decode_space()
{
  auto& pages = _pass_itm_data->pages_info;

  // TODO: this could be made smaller if we ignored dictionary pages and pages with no
  // repetition data.
  size_t const per_page_decode_buf_size =
    LEVEL_DECODE_BUF_SIZE * 2 * _pass_itm_data->level_type_size;
  auto const decode_buf_size = per_page_decode_buf_size * pages.size();
  _pass_itm_data->level_decode_data =
    rmm::device_buffer(decode_buf_size, _stream, rmm::mr::get_current_device_resource());

  // distribute the buffers
  uint8_t* buf = static_cast<uint8_t*>(_pass_itm_data->level_decode_data.data());
  for (size_t idx = 0; idx < pages.size(); idx++) {
    auto& p = pages[idx];

    p.lvl_decode_buf[level_type::DEFINITION] = buf;
    buf += (LEVEL_DECODE_BUF_SIZE * _pass_itm_data->level_type_size);
    p.lvl_decode_buf[level_type::REPETITION] = buf;
    buf += (LEVEL_DECODE_BUF_SIZE * _pass_itm_data->level_type_size);
  }
}

std::pair<bool, std::vector<std::future<void>>> reader::impl::read_and_decompress_column_chunks()
{
  auto const& row_groups_info = _pass_itm_data->row_groups;
  auto const num_rows         = _pass_itm_data->num_rows;

  auto& raw_page_data = _pass_itm_data->raw_page_data;
  auto& chunks        = _pass_itm_data->chunks;

  // Descriptors for all the chunks that make up the selected columns
  auto const num_input_columns = _input_columns.size();
  auto const num_chunks        = row_groups_info.size() * num_input_columns;

  // Association between each column chunk and its source
  std::vector<size_type> chunk_source_map(num_chunks);

  // Tracker for eventually deallocating compressed and uncompressed data
  raw_page_data = std::vector<std::unique_ptr<datasource::buffer>>(num_chunks);

  // Keep track of column chunk file offsets
  std::vector<size_t> column_chunk_offsets(num_chunks);

  // Initialize column chunk information
  size_t total_decompressed_size = 0;
  auto remaining_rows            = num_rows;
  std::vector<std::future<void>> read_chunk_tasks;
  size_type chunk_count = 0;
  for (auto const& rg : row_groups_info) {
    auto const& row_group       = _metadata->get_row_group(rg.index, rg.source_index);
    auto const row_group_source = rg.source_index;
    auto const row_group_rows   = std::min<int>(remaining_rows, row_group.num_rows);

    // generate ColumnChunkDesc objects for everything to be decoded (all input columns)
    for (size_t i = 0; i < num_input_columns; ++i) {
      auto const& col = _input_columns[i];
      // look up metadata
      auto& col_meta = _metadata->get_column_metadata(rg.index, rg.source_index, col.schema_idx);

      column_chunk_offsets[chunk_count] =
        (col_meta.dictionary_page_offset != 0)
          ? std::min(col_meta.data_page_offset, col_meta.dictionary_page_offset)
          : col_meta.data_page_offset;

      // Map each column chunk to its column index and its source index
      chunk_source_map[chunk_count] = row_group_source;

      if (col_meta.codec != Compression::UNCOMPRESSED) {
        total_decompressed_size += col_meta.total_uncompressed_size;
      }

      chunk_count++;
    }
    remaining_rows -= row_group_rows;
  }

  // Read compressed chunk data to device memory
  read_chunk_tasks.push_back(read_column_chunks_async(_sources,
                                                      raw_page_data,
                                                      chunks,
                                                      0,
                                                      chunks.size(),
                                                      column_chunk_offsets,
                                                      chunk_source_map,
                                                      _stream));

  CUDF_EXPECTS(remaining_rows == 0, "All rows data must be read.");

  return {total_decompressed_size > 0, std::move(read_chunk_tasks)};
}

void reader::impl::load_and_decompress_data()
{
  // This function should never be called if `num_rows == 0`.
  CUDF_EXPECTS(_pass_itm_data->num_rows > 0, "Number of reading rows must not be zero.");

  auto& raw_page_data    = _pass_itm_data->raw_page_data;
  auto& decomp_page_data = _pass_itm_data->decomp_page_data;
  auto& chunks           = _pass_itm_data->chunks;
  auto& pages            = _pass_itm_data->pages_info;

  auto const [has_compressed_data, read_chunks_tasks] = read_and_decompress_column_chunks();

  for (auto& task : read_chunks_tasks) {
    task.wait();
  }

  // Process dataset chunk pages into output columns
  auto const total_pages = count_page_headers(chunks, _stream);
  if (total_pages <= 0) { return; }
  pages = cudf::detail::hostdevice_vector<PageInfo>(total_pages, total_pages, _stream);

  // decoding of column/page information
  _pass_itm_data->level_type_size = decode_page_headers(chunks, pages, _stream);
  if (has_compressed_data) {
    decomp_page_data = decompress_page_data(chunks, pages, _stream);
    // Free compressed data
    for (size_t c = 0; c < chunks.size(); c++) {
      if (chunks[c].codec != Compression::UNCOMPRESSED) { raw_page_data[c].reset(); }
    }
  }

  // build output column info
  // walk the schema, building out_buffers that mirror what our final cudf columns will look
  // like. important : there is not necessarily a 1:1 mapping between input columns and output
  // columns. For example, parquet does not explicitly store a ColumnChunkDesc for struct
  // columns. The "structiness" is simply implied by the schema.  For example, this schema:
  //  required group field_id=1 name {
  //    required binary field_id=2 firstname (String);
  //    required binary field_id=3 middlename (String);
  //    required binary field_id=4 lastname (String);
  // }
  // will only contain 3 columns of data (firstname, middlename, lastname).  But of course
  // "name" is a struct column that we want to return, so we have to make sure that we
  // create it ourselves.
  // std::vector<output_column_info> output_info = build_output_column_info();

  // the following two allocate functions modify the page data
  pages.device_to_host_sync(_stream);
  {
    // nesting information (sizes, etc) stored -per page-
    // note : even for flat schemas, we allocate 1 level of "nesting" info
    allocate_nesting_info();

    // level decode space
    allocate_level_decode_space();
  }
  pages.host_to_device_async(_stream);
}

namespace {

struct cumulative_row_info {
  size_t row_count;   // cumulative row count
  size_t size_bytes;  // cumulative size in bytes
  int key;            // schema index
};

#if defined(PREPROCESS_DEBUG)
void print_pages(cudf::detail::hostdevice_vector<PageInfo>& pages, rmm::cuda_stream_view _stream)
{
  pages.device_to_host_sync(_stream);
  for (size_t idx = 0; idx < pages.size(); idx++) {
    auto const& p = pages[idx];
    // skip dictionary pages
    if (p.flags & PAGEINFO_FLAGS_DICTIONARY) { continue; }
    printf(
      "P(%lu, s:%d): chunk_row(%d), num_rows(%d), skipped_values(%d), skipped_leaf_values(%d), "
      "str_bytes(%d)\n",
      idx,
      p.src_col_schema,
      p.chunk_row,
      p.num_rows,
      p.skipped_values,
      p.skipped_leaf_values,
      p.str_bytes);
  }
}
#endif  // PREPROCESS_DEBUG

struct get_page_chunk_idx {
  __device__ size_type operator()(PageInfo const& page) { return page.chunk_idx; }
};

struct get_page_num_rows {
  __device__ size_type operator()(PageInfo const& page) { return page.num_rows; }
};

struct get_page_column_index {
  ColumnChunkDesc const* chunks;
  __device__ size_type operator()(PageInfo const& page)
  {
    return chunks[page.chunk_idx].src_col_index;
  }
};

struct input_col_info {
  int const schema_idx;
  size_type const nesting_depth;
};

/**
 * @brief Converts a 1-dimensional index into page, depth and column indices used in
 * allocate_columns to compute columns sizes.
 *
 * The input index will iterate through pages, nesting depth and column indices in that order.
 */
struct reduction_indices {
  size_t const page_idx;
  size_type const depth_idx;
  size_type const col_idx;

  __device__ reduction_indices(size_t index_, size_type max_depth_, size_t num_pages_)
    : page_idx(index_ % num_pages_),
      depth_idx((index_ / num_pages_) % max_depth_),
      col_idx(index_ / (max_depth_ * num_pages_))
  {
  }
};

/**
 * @brief Returns the size field of a PageInfo struct for a given depth, keyed by schema.
 */
struct get_page_nesting_size {
  input_col_info const* const input_cols;
  size_type const max_depth;
  size_t const num_pages;
  PageInfo const* const pages;
  int const* page_indices;

  __device__ size_type operator()(size_t index) const
  {
    auto const indices = reduction_indices{index, max_depth, num_pages};

    auto const& page = pages[page_indices[indices.page_idx]];
    if (page.src_col_schema != input_cols[indices.col_idx].schema_idx ||
        page.flags & PAGEINFO_FLAGS_DICTIONARY ||
        indices.depth_idx >= input_cols[indices.col_idx].nesting_depth) {
      return 0;
    }

    return page.nesting[indices.depth_idx].batch_size;
  }
};

struct get_reduction_key {
  size_t const num_pages;
  __device__ size_t operator()(size_t index) const { return index / num_pages; }
};

/**
 * @brief Writes to the chunk_row field of the PageInfo struct.
 */
struct chunk_row_output_iter {
  PageInfo* p;
  using value_type        = size_type;
  using difference_type   = size_type;
  using pointer           = size_type*;
  using reference         = size_type&;
  using iterator_category = thrust::output_device_iterator_tag;

  __host__ __device__ chunk_row_output_iter operator+(int i)
  {
    return chunk_row_output_iter{p + i};
  }

  __host__ __device__ void operator++() { p++; }

  __device__ reference operator[](int i) { return p[i].chunk_row; }
  __device__ reference operator*() { return p->chunk_row; }
};

/**
 * @brief Writes to the page_start_value field of the PageNestingInfo struct, keyed by schema.
 */
struct start_offset_output_iterator {
  PageInfo const* pages;
  int const* page_indices;
  size_t cur_index;
  input_col_info const* input_cols;
  size_type max_depth;
  size_t num_pages;
  int empty               = 0;
  using value_type        = size_type;
  using difference_type   = size_type;
  using pointer           = size_type*;
  using reference         = size_type&;
  using iterator_category = thrust::output_device_iterator_tag;

  constexpr void operator=(start_offset_output_iterator const& other)
  {
    pages        = other.pages;
    page_indices = other.page_indices;
    cur_index    = other.cur_index;
    input_cols   = other.input_cols;
    max_depth    = other.max_depth;
    num_pages    = other.num_pages;
  }

  constexpr start_offset_output_iterator operator+(size_t i)
  {
    return start_offset_output_iterator{
      pages, page_indices, cur_index + i, input_cols, max_depth, num_pages};
  }

  constexpr void operator++() { cur_index++; }

  __device__ reference operator[](size_t i) { return dereference(cur_index + i); }
  __device__ reference operator*() { return dereference(cur_index); }

 private:
  __device__ reference dereference(size_t index)
  {
    auto const indices = reduction_indices{index, max_depth, num_pages};

    PageInfo const& p = pages[page_indices[indices.page_idx]];
    if (p.src_col_schema != input_cols[indices.col_idx].schema_idx ||
        p.flags & PAGEINFO_FLAGS_DICTIONARY ||
        indices.depth_idx >= input_cols[indices.col_idx].nesting_depth) {
      return empty;
    }
    return p.nesting_decode[indices.depth_idx].page_start_value;
  }
};

struct flat_column_num_rows {
  PageInfo const* pages;
  ColumnChunkDesc const* chunks;

  __device__ size_type operator()(size_type pindex) const
  {
    PageInfo const& page = pages[pindex];
    // ignore dictionary pages and pages belonging to any column containing repetition (lists)
    if ((page.flags & PAGEINFO_FLAGS_DICTIONARY) ||
        (chunks[page.chunk_idx].max_level[level_type::REPETITION] > 0)) {
      return 0;
    }
    return page.num_rows;
  }
};

struct row_counts_nonzero {
  __device__ bool operator()(size_type count) const { return count > 0; }
};

struct row_counts_different {
  size_type const expected;
  __device__ bool operator()(size_type count) const { return (count != 0) && (count != expected); }
};

/**
 * @brief Detect malformed parquet input data.
 *
 * We have seen cases where parquet files can be oddly malformed. This function specifically
 * detects one case in particular:
 *
 * - When you have a file containing N rows
 * - For some reason, the sum total of the number of rows over all pages for a given column
 *   is != N
 *
 * @param pages All pages to be decoded
 * @param chunks Chunk data
 * @param page_keys Keys (schema id) associated with each page, sorted by column
 * @param page_index Page indices for iteration, sorted by column
 * @param expected_row_count Expected row count, if applicable
 * @param stream CUDA stream used for device memory operations and kernel launches
 */
void detect_malformed_pages(cudf::detail::hostdevice_vector<PageInfo>& pages,
                            cudf::detail::hostdevice_vector<ColumnChunkDesc> const& chunks,
                            device_span<int const> page_keys,
                            device_span<int const> page_index,
                            std::optional<size_t> expected_row_count,
                            rmm::cuda_stream_view stream)
{
  // sum row counts for all non-dictionary, non-list columns. other columns will be indicated as 0
  rmm::device_uvector<size_type> row_counts(pages.size(),
                                            stream);  // worst case:  num keys == num pages
  auto const size_iter = thrust::make_transform_iterator(
    page_index.begin(), flat_column_num_rows{pages.device_ptr(), chunks.device_ptr()});
  auto const row_counts_begin = row_counts.begin();
  auto const row_counts_end   = thrust::reduce_by_key(rmm::exec_policy(stream),
                                                    page_keys.begin(),
                                                    page_keys.end(),
                                                    size_iter,
                                                    thrust::make_discard_iterator(),
                                                    row_counts_begin)
                                .second;

  // make sure all non-zero row counts are the same
  rmm::device_uvector<size_type> compacted_row_counts(pages.size(), stream);
  auto const compacted_row_counts_begin = compacted_row_counts.begin();
  auto const compacted_row_counts_end   = thrust::copy_if(rmm::exec_policy(stream),
                                                        row_counts_begin,
                                                        row_counts_end,
                                                        compacted_row_counts_begin,
                                                        row_counts_nonzero{});
  if (compacted_row_counts_end != compacted_row_counts_begin) {
    size_t const found_row_count = static_cast<size_t>(compacted_row_counts.element(0, stream));

    // if we somehow don't match the expected row count from the row groups themselves
    if (expected_row_count.has_value()) {
      CUDF_EXPECTS(expected_row_count.value() == found_row_count,
                   "Encountered malformed parquet page data (unexpected row count in page data)");
    }

    // all non-zero row counts must be the same
    auto const chk =
      thrust::count_if(rmm::exec_policy(stream),
                       compacted_row_counts_begin,
                       compacted_row_counts_end,
                       row_counts_different{static_cast<size_type>(found_row_count)});
    CUDF_EXPECTS(chk == 0,
                 "Encountered malformed parquet page data (row count mismatch in page data)");
  }
}

struct page_to_string_size {
  PageInfo* pages;
  ColumnChunkDesc const* chunks;

  __device__ size_t operator()(size_type page_idx) const
  {
    auto const page  = pages[page_idx];
    auto const chunk = chunks[page.chunk_idx];

    if (not is_string_col(chunk) || (page.flags & PAGEINFO_FLAGS_DICTIONARY) != 0) { return 0; }
    return pages[page_idx].str_bytes;
  }
};

struct page_offset_output_iter {
  PageInfo* p;
  size_type const* index;

  using value_type        = size_type;
  using difference_type   = size_type;
  using pointer           = size_type*;
  using reference         = size_type&;
  using iterator_category = thrust::output_device_iterator_tag;

  __host__ __device__ page_offset_output_iter operator+(int i)
  {
    return page_offset_output_iter{p, index + i};
  }

  __host__ __device__ void operator++() { index++; }

  __device__ reference operator[](int i) { return p[index[i]].str_offset; }
  __device__ reference operator*() { return p[*index].str_offset; }
};

}  // anonymous namespace

void reader::impl::preprocess_pages(bool uses_custom_row_bounds, size_t chunk_read_limit)
{
  auto const skip_rows = _pass_itm_data->skip_rows;
  auto const num_rows  = _pass_itm_data->num_rows;
  auto& chunks         = _pass_itm_data->chunks;
  auto& pages          = _pass_itm_data->pages_info;

  // compute page ordering.
  //
  // ordering of pages is by input column schema, repeated across row groups.  so
  // if we had 3 columns, each with 2 pages, and 1 row group, our schema values might look like
  //
  // 1, 1, 2, 2, 3, 3
  //
  // However, if we had more than one row group, the pattern would be
  //
  // 1, 1, 2, 2, 3, 3, 1, 1, 2, 2, 3, 3
  // ^ row group 0     |
  //                   ^ row group 1
  //
  // To process pages by key (exclusive_scan_by_key, reduce_by_key, etc), the ordering we actually
  // want is
  //
  // 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3
  //
  // We also need to preserve key-relative page ordering, so we need to use a stable sort.
  rmm::device_uvector<int> page_keys(pages.size(), _stream);
  rmm::device_uvector<int> page_index(pages.size(), _stream);
  {
    thrust::transform(rmm::exec_policy(_stream),
                      pages.device_ptr(),
                      pages.device_ptr() + pages.size(),
                      page_keys.begin(),
                      get_page_column_index{chunks.device_ptr()});

    thrust::sequence(rmm::exec_policy(_stream), page_index.begin(), page_index.end());
    thrust::stable_sort_by_key(rmm::exec_policy(_stream),
                               page_keys.begin(),
                               page_keys.end(),
                               page_index.begin(),
                               thrust::less<int>());
  }

  // detect malformed columns.
  // - we have seen some cases in the wild where we have a row group containing N
  //   rows, but the total number of rows in the pages for column X is != N. while it
  //   is possible to load this by just capping the number of rows read, we cannot tell
  //   which rows are invalid so we may be returning bad data. in addition, this mismatch
  //   confuses the chunked reader
  detect_malformed_pages(pages,
                         chunks,
                         page_keys,
                         page_index,
                         uses_custom_row_bounds ? std::nullopt : std::make_optional(num_rows),
                         _stream);

  // iterate over all input columns and determine if they contain lists so we can further
  // preprocess them.
  bool has_lists = false;
  for (size_t idx = 0; idx < _input_columns.size(); idx++) {
    auto const& input_col  = _input_columns[idx];
    size_t const max_depth = input_col.nesting_depth();

    auto* cols = &_output_buffers;
    for (size_t l_idx = 0; l_idx < max_depth; l_idx++) {
      auto& out_buf = (*cols)[input_col.nesting[l_idx]];
      cols          = &out_buf.children;

      // if this has a list parent, we have to get column sizes from the
      // data computed during ComputePageSizes
      if (out_buf.user_data & PARQUET_COLUMN_BUFFER_FLAG_HAS_LIST_PARENT) {
        has_lists = true;
        break;
      }
    }
    if (has_lists) { break; }
  }

  // generate string dict indices if necessary
  {
    auto is_dict_chunk = [](ColumnChunkDesc const& chunk) {
      return (chunk.data_type & 0x7) == BYTE_ARRAY && chunk.num_dict_pages > 0;
    };

    // Count the number of string dictionary entries
    // NOTE: Assumes first page in the chunk is always the dictionary page
    size_t total_str_dict_indexes = 0;
    for (size_t c = 0, page_count = 0; c < chunks.size(); c++) {
      if (is_dict_chunk(chunks[c])) {
        total_str_dict_indexes += pages[page_count].num_input_values;
      }
      page_count += chunks[c].max_num_pages;
    }

    // Build index for string dictionaries since they can't be indexed
    // directly due to variable-sized elements
    _pass_itm_data->str_dict_index =
      cudf::detail::make_zeroed_device_uvector_async<string_index_pair>(
        total_str_dict_indexes, _stream, rmm::mr::get_current_device_resource());

    // Update chunks with pointers to string dict indices
    for (size_t c = 0, page_count = 0, str_ofs = 0; c < chunks.size(); c++) {
      input_column_info const& input_col = _input_columns[chunks[c].src_col_index];
      CUDF_EXPECTS(input_col.schema_idx == chunks[c].src_col_schema,
                   "Column/page schema index mismatch");
      if (is_dict_chunk(chunks[c])) {
        chunks[c].str_dict_index = _pass_itm_data->str_dict_index.data() + str_ofs;
        str_ofs += pages[page_count].num_input_values;
      }

      // column_data_base will always point to leaf data, even for nested types.
      page_count += chunks[c].max_num_pages;
    }

    if (total_str_dict_indexes > 0) {
      chunks.host_to_device_async(_stream);
      BuildStringDictionaryIndex(chunks.device_ptr(), chunks.size(), _stream);
    }
  }

  // intermediate data we will need for further chunked reads
  if (has_lists || chunk_read_limit > 0) {
    // computes:
    // PageNestingInfo::num_rows for each page. the true number of rows (taking repetition into
    // account), not just the number of values. PageNestingInfo::size for each level of nesting, for
    // each page.
    //
    // we will be applying a later "trim" pass if skip_rows/num_rows is being used, which can happen
    // if:
    // - user has passed custom row bounds
    // - we will be doing a chunked read
    ComputePageSizes(pages,
                     chunks,
                     0,  // 0-max size_t. process all possible rows
                     std::numeric_limits<size_t>::max(),
                     true,                  // compute num_rows
                     chunk_read_limit > 0,  // compute string sizes
                     _pass_itm_data->level_type_size,
                     _stream);

    // computes:
    // PageInfo::chunk_row (the absolute start row index) for all pages
    // Note: this is doing some redundant work for pages in flat hierarchies.  chunk_row has already
    // been computed during header decoding. the overall amount of work here is very small though.
    auto key_input  = thrust::make_transform_iterator(pages.device_ptr(), get_page_chunk_idx{});
    auto page_input = thrust::make_transform_iterator(pages.device_ptr(), get_page_num_rows{});
    thrust::exclusive_scan_by_key(rmm::exec_policy(_stream),
                                  key_input,
                                  key_input + pages.size(),
                                  page_input,
                                  chunk_row_output_iter{pages.device_ptr()});

    // retrieve pages back
    pages.device_to_host_sync(_stream);

    // print_pages(pages, _stream);
  }

  // preserve page ordering data for string decoder
  _pass_itm_data->page_keys  = std::move(page_keys);
  _pass_itm_data->page_index = std::move(page_index);

  // compute splits for the pass
  compute_splits_for_pass();
}

void reader::impl::allocate_columns(size_t skip_rows, size_t num_rows, bool uses_custom_row_bounds)
{
  auto const& chunks = _pass_itm_data->chunks;
  auto& pages        = _pass_itm_data->pages_info;

  // Should not reach here if there is no page data.
  CUDF_EXPECTS(pages.size() > 0, "There is no page to parse");

  // computes:
  // PageNestingInfo::batch_size for each level of nesting, for each page, taking row bounds into
  // account. PageInfo::skipped_values, which tells us where to start decoding in the input to
  // respect the user bounds. It is only necessary to do this second pass if uses_custom_row_bounds
  // is set (if the user has specified artificial bounds).
  if (uses_custom_row_bounds) {
    ComputePageSizes(pages,
                     chunks,
                     skip_rows,
                     num_rows,
                     false,  // num_rows is already computed
                     false,  // no need to compute string sizes
                     _pass_itm_data->level_type_size,
                     _stream);

    // print_pages(pages, _stream);
  }

  // iterate over all input columns and allocate any associated output
  // buffers if they are not part of a list hierarchy. mark down
  // if we have any list columns that need further processing.
  bool has_lists = false;
  for (size_t idx = 0; idx < _input_columns.size(); idx++) {
    auto const& input_col  = _input_columns[idx];
    size_t const max_depth = input_col.nesting_depth();

    auto* cols = &_output_buffers;
    for (size_t l_idx = 0; l_idx < max_depth; l_idx++) {
      auto& out_buf = (*cols)[input_col.nesting[l_idx]];
      cols          = &out_buf.children;

      // if this has a list parent, we have to get column sizes from the
      // data computed during ComputePageSizes
      if (out_buf.user_data & PARQUET_COLUMN_BUFFER_FLAG_HAS_LIST_PARENT) {
        has_lists = true;
      }
      // if we haven't already processed this column because it is part of a struct hierarchy
      else if (out_buf.size == 0) {
        // add 1 for the offset if this is a list column
        out_buf.create(
          out_buf.type.id() == type_id::LIST && l_idx < max_depth ? num_rows + 1 : num_rows,
          _stream,
          _mr);
      }
    }
  }

  // compute output column sizes by examining the pages of the -input- columns
  if (has_lists) {
    auto& page_index = _pass_itm_data->page_index;

    std::vector<input_col_info> h_cols_info;
    h_cols_info.reserve(_input_columns.size());
    std::transform(_input_columns.cbegin(),
                   _input_columns.cend(),
                   std::back_inserter(h_cols_info),
                   [](auto& col) -> input_col_info {
                     return {col.schema_idx, static_cast<size_type>(col.nesting_depth())};
                   });

    auto const max_depth =
      (*std::max_element(h_cols_info.cbegin(),
                         h_cols_info.cend(),
                         [](auto& l, auto& r) { return l.nesting_depth < r.nesting_depth; }))
        .nesting_depth;

    auto const d_cols_info = cudf::detail::make_device_uvector_async(
      h_cols_info, _stream, rmm::mr::get_current_device_resource());

    auto const num_keys = _input_columns.size() * max_depth * pages.size();
    // size iterator. indexes pages by sorted order
    rmm::device_uvector<size_type> size_input{num_keys, _stream};
    thrust::transform(
      rmm::exec_policy(_stream),
      thrust::make_counting_iterator<size_type>(0),
      thrust::make_counting_iterator<size_type>(num_keys),
      size_input.begin(),
      get_page_nesting_size{
        d_cols_info.data(), max_depth, pages.size(), pages.device_ptr(), page_index.begin()});
    auto const reduction_keys =
      cudf::detail::make_counting_transform_iterator(0, get_reduction_key{pages.size()});
    cudf::detail::hostdevice_vector<size_t> sizes{_input_columns.size() * max_depth, _stream};

    // find the size of each column
    thrust::reduce_by_key(rmm::exec_policy(_stream),
                          reduction_keys,
                          reduction_keys + num_keys,
                          size_input.cbegin(),
                          thrust::make_discard_iterator(),
                          sizes.d_begin());

    // for nested hierarchies, compute per-page start offset
    thrust::exclusive_scan_by_key(
      rmm::exec_policy(_stream),
      reduction_keys,
      reduction_keys + num_keys,
      size_input.cbegin(),
      start_offset_output_iterator{
        pages.device_ptr(), page_index.begin(), 0, d_cols_info.data(), max_depth, pages.size()});

    sizes.device_to_host_sync(_stream);
    for (size_type idx = 0; idx < static_cast<size_type>(_input_columns.size()); idx++) {
      auto const& input_col = _input_columns[idx];
      auto* cols            = &_output_buffers;
      for (size_type l_idx = 0; l_idx < static_cast<size_type>(input_col.nesting_depth());
           l_idx++) {
        auto& out_buf = (*cols)[input_col.nesting[l_idx]];
        cols          = &out_buf.children;
        // if this buffer is part of a list hierarchy, we need to determine it's
        // final size and allocate it here.
        //
        // for struct columns, higher levels of the output columns are shared between input
        // columns. so don't compute any given level more than once.
        if ((out_buf.user_data & PARQUET_COLUMN_BUFFER_FLAG_HAS_LIST_PARENT) && out_buf.size == 0) {
          auto size = sizes[(idx * max_depth) + l_idx];

          // if this is a list column add 1 for non-leaf levels for the terminating offset
          if (out_buf.type.id() == type_id::LIST && l_idx < max_depth) { size++; }

          // allocate
          out_buf.create(size, _stream, _mr);
        }
      }
    }
  }
}

std::vector<size_t> reader::impl::calculate_page_string_offsets()
{
  auto& chunks           = _pass_itm_data->chunks;
  auto& pages            = _pass_itm_data->pages_info;
  auto const& page_keys  = _pass_itm_data->page_keys;
  auto const& page_index = _pass_itm_data->page_index;

  std::vector<size_t> col_sizes(_input_columns.size(), 0L);
  rmm::device_uvector<size_t> d_col_sizes(col_sizes.size(), _stream);

  // use page_index to fetch page string sizes in the proper order
  auto val_iter = thrust::make_transform_iterator(
    page_index.begin(), page_to_string_size{pages.device_ptr(), chunks.device_ptr()});

  // do scan by key to calculate string offsets for each page
  thrust::exclusive_scan_by_key(rmm::exec_policy(_stream),
                                page_keys.begin(),
                                page_keys.end(),
                                val_iter,
                                page_offset_output_iter{pages.device_ptr(), page_index.data()});

  // now sum up page sizes
  rmm::device_uvector<int> reduce_keys(col_sizes.size(), _stream);
  thrust::reduce_by_key(rmm::exec_policy(_stream),
                        page_keys.begin(),
                        page_keys.end(),
                        val_iter,
                        reduce_keys.begin(),
                        d_col_sizes.begin());

  cudaMemcpyAsync(col_sizes.data(),
                  d_col_sizes.data(),
                  sizeof(size_t) * col_sizes.size(),
                  cudaMemcpyDeviceToHost,
                  _stream);
  _stream.synchronize();

  return col_sizes;
}

}  // namespace cudf::io::parquet::detail
