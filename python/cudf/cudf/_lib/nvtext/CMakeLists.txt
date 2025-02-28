# =============================================================================
# Copyright (c) 2022-2023, NVIDIA CORPORATION.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except
# in compliance with the License. You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software distributed under the License
# is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express
# or implied. See the License for the specific language governing permissions and limitations under
# the License.
# =============================================================================

set(cython_sources
    edit_distance.pyx generate_ngrams.pyx jaccard.pyx minhash.pyx ngrams_tokenize.pyx normalize.pyx
    replace.pyx stemmer.pyx subword_tokenize.pyx tokenize.pyx
)
set(linked_libraries cudf::cudf)
rapids_cython_create_modules(
  CXX
  SOURCE_FILES "${cython_sources}"
  LINKED_LIBRARIES "${linked_libraries}" MODULE_PREFIX nvtext_ ASSOCIATED_TARGETS cudf
)
# TODO: Due to cudf's scalar.pyx needing to cimport pylibcudf's scalar.pyx (because there are parts
# of cudf Cython that need to directly access the c_obj underlying the pylibcudf Scalar) the
# requirement for arrow headers infects all of cudf. That in turn requires including numpy headers.
# These requirements will go away once all scalar-related Cython code is removed from cudf.
foreach(target IN LISTS RAPIDS_CYTHON_CREATED_TARGETS)
  target_include_directories(${target} PRIVATE "${NumPy_INCLUDE_DIRS}")
  target_include_directories(${target} PRIVATE "${PYARROW_INCLUDE_DIR}")
endforeach()
