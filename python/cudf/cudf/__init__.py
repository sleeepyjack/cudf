# Copyright (c) 2018-2023, NVIDIA CORPORATION.

# _setup_numba _must be called before numba.cuda is imported, because
# it sets the numba config variable responsible for enabling
# Minor Version Compatibility. Setting it after importing numba.cuda has no effect.
from cudf.utils._numba import _setup_numba
from cudf.utils.gpu_utils import validate_setup

_setup_numba()
validate_setup()

import cupy
from numba import config as numba_config, cuda

import rmm
from rmm.allocators.cupy import rmm_cupy_allocator
from rmm.allocators.numba import RMMNumbaManager

from cudf import api, core, datasets, testing
from cudf.api.extensions import (
    register_dataframe_accessor,
    register_index_accessor,
    register_series_accessor,
)
from cudf.api.types import dtype
from cudf.core.algorithms import factorize
from cudf.core.cut import cut
from cudf.core.dataframe import DataFrame, from_dataframe, from_pandas, merge
from cudf.core.dtypes import (
    CategoricalDtype,
    Decimal32Dtype,
    Decimal64Dtype,
    Decimal128Dtype,
    IntervalDtype,
    ListDtype,
    StructDtype,
)
from cudf.core.groupby import Grouper
from cudf.core.index import (
    BaseIndex,
    CategoricalIndex,
    DatetimeIndex,
    Float32Index,
    Float64Index,
    GenericIndex,
    Index,
    Int8Index,
    Int16Index,
    Int32Index,
    Int64Index,
    IntervalIndex,
    RangeIndex,
    StringIndex,
    TimedeltaIndex,
    UInt8Index,
    UInt16Index,
    UInt32Index,
    UInt64Index,
    interval_range,
)
from cudf.core.missing import NA, NaT
from cudf.core.multiindex import MultiIndex
from cudf.core.reshape import (
    concat,
    crosstab,
    get_dummies,
    melt,
    pivot,
    pivot_table,
    unstack,
)
from cudf.core.scalar import Scalar
from cudf.core.series import Series, isclose
from cudf.core.tools.datetimes import DateOffset, date_range, to_datetime
from cudf.core.tools.numeric import to_numeric
from cudf.io import (
    from_dlpack,
    read_avro,
    read_csv,
    read_feather,
    read_hdf,
    read_json,
    read_orc,
    read_parquet,
    read_text,
)
from cudf.options import (
    describe_option,
    get_option,
    option_context,
    set_option,
)
from cudf.utils.utils import clear_cache

cuda.set_memory_manager(RMMNumbaManager)
cupy.cuda.set_allocator(rmm_cupy_allocator)


rmm.register_reinitialize_hook(clear_cache)


__version__ = "23.12.00"

__all__ = [
    "BaseIndex",
    "CategoricalDtype",
    "CategoricalIndex",
    "DataFrame",
    "DateOffset",
    "DatetimeIndex",
    "Decimal32Dtype",
    "Decimal64Dtype",
    "Float32Index",
    "Float64Index",
    "GenericIndex",
    "Grouper",
    "Index",
    "Int16Index",
    "Int32Index",
    "Int64Index",
    "Int8Index",
    "IntervalDtype",
    "IntervalIndex",
    "ListDtype",
    "MultiIndex",
    "NA",
    "NaT",
    "RangeIndex",
    "Scalar",
    "Series",
    "StringIndex",
    "StructDtype",
    "TimedeltaIndex",
    "UInt16Index",
    "UInt32Index",
    "UInt64Index",
    "UInt8Index",
    "api",
    "concat",
    "crosstab",
    "cut",
    "date_range",
    "describe_option",
    "factorize",
    "from_dataframe",
    "from_dlpack",
    "from_pandas",
    "get_dummies",
    "get_option",
    "interval_range",
    "isclose",
    "melt",
    "merge",
    "pivot",
    "pivot_table",
    "read_avro",
    "read_csv",
    "read_feather",
    "read_hdf",
    "read_json",
    "read_orc",
    "read_parquet",
    "read_text",
    "set_option",
    "testing",
    "to_datetime",
    "to_numeric",
    "unstack",
]
