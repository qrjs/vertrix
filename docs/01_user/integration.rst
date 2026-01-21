Core Integration
================

There are two ways to integrate Vicuna into a custom RTL design:

* Integrate the vector coprocessor only by instantiating the ``vproc_core`` module.

* Integrate the vector coprocessor together with a main core
  and optional instruction and data caches
  by instantiating the ``vproc_top`` module.


Integrate Vicuna alone
----------------------

Instantiate the ``vproc_core`` module using the following instantiation template:

.. code-block:: systemverilog

   vproc_core #(
       .INSTR_ID_W         (                    ),
       .VMEM_W             (                    ),
       .DONT_CARE_ZERO     (                    ),
       .ASYNC_RESET        (                    )
   ) v_core (
       .clk_i              (                    ),
       .rst_ni             (                    ),

       .issue_valid_i      (                    ),
       .issue_ready_o      (                    ),
       .issue_instr_i      (                    ),
       .issue_mode_i       (                    ),
       .issue_id_i         (                    ),
       .issue_rs1_i        (                    ),
       .issue_rs2_i        (                    ),
       .issue_rs_valid_i   (                    ),
       .issue_accept_o     (                    ),
       .issue_writeback_o  (                    ),
       .issue_dualwrite_o  (                    ),
       .issue_dualread_o   (                    ),
       .issue_loadstore_o  (                    ),
       .issue_exc_o        (                    ),

       .commit_valid_i     (                    ),
       .commit_id_i        (                    ),
       .commit_kill_i      (                    ),

       .vlsu_mem_valid_o   (                    ),
       .vlsu_mem_ready_i   (                    ),
       .vlsu_mem_id_o      (                    ),
       .vlsu_mem_addr_o    (                    ),
       .vlsu_mem_we_o      (                    ),
       .vlsu_mem_be_o      (                    ),
       .vlsu_mem_wdata_o   (                    ),
       .vlsu_mem_last_o    (                    ),
       .vlsu_mem_spec_o    (                    ),
       .vlsu_mem_resp_exc_i     (                    ),
       .vlsu_mem_resp_exccode_i (                    ),
       .vlsu_mem_result_valid_i (                    ),
       .vlsu_mem_result_id_i    (                    ),
       .vlsu_mem_result_rdata_i (                    ),
       .vlsu_mem_result_err_i   (                    ),

       .result_valid_o     (                    ),
       .result_ready_i     (                    ),
       .result_id_o        (                    ),
       .result_data_o      (                    ),
       .result_rd_o        (                    ),
       .result_we_o        (                    ),
       .result_exc_o       (                    ),
       .result_exccode_o   (                    ),
       .result_err_o       (                    ),
       .result_dbg_o       (                    ),

       .pending_load_o     (                    ),
       .pending_store_o    (                    ),

       .csr_vtype_o        (                    ),
       .csr_vl_o           (                    ),
       .csr_vlenb_o        (                    ),
       .csr_vstart_o       (                    ),
       .csr_vstart_i       (                    ),
       .csr_vstart_set_i   (                    ),
       .csr_vxrm_o         (                    ),
       .csr_vxrm_i         (                    ),
       .csr_vxrm_set_i     (                    ),
       .csr_vxsat_o        (                    ),
       .csr_vxsat_i        (                    ),
       .csr_vxsat_set_i    (                    ),

       .pend_vreg_wr_map_o (                    )
   );


.. _core_parameters:

Parameters that should be set when instantiating the ``vproc_core`` module
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Mandatory parameters related to the direct coupling interface
(must be specified, default values cause compilation errors):

+-------------------+--------------------------------+--------------------------------------------+
| Name              | Type                           | Description                                |
+===================+================================+============================================+
|``INSTR_ID_W``     |``int unsigned``                | Width of instruction IDs (bits)            |
+-------------------+--------------------------------+--------------------------------------------+
|``VMEM_W``         |``int unsigned``                | Width of vector memory interface (bits)    |
+-------------------+--------------------------------+--------------------------------------------+

Don't care policy and reset properties
(default values as indicated):

+-------------------+-------+--------+------------------------------------------------------------+
| Name              | Type  | Default| Description                                                |
+===================+=======+========+============================================================+
|``DONT_CARE_ZERO`` |``bit``|``1'b0``| If set, use ``'0`` for don't care values rather than ``'x``|
+-------------------+-------+--------+------------------------------------------------------------+
|``ASYNC_RESET``    |``bit``|``1'b0``| Set if ``rst_ni`` is asynchronous instead of synchronous   |
+-------------------+-------+--------+------------------------------------------------------------+


.. _core_parameters_config:

Parameters that should be **not be overridden** when instantiating the ``vproc_core`` module
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Vector register file configuration
(default values taken from configuration package ``vproc_config``):

+-------------------+--------------------------------+--------------------------------------------+
| Name              | Type                           | Description                                |
+===================+================================+============================================+
|``VREG_TYPE``      |``vproc_pkg::vreg_type``        | Vector register file type                  |
+-------------------+--------------------------------+--------------------------------------------+
|``VREG_W``         |``int unsigned``                | Width of the vector registers (bits)       |
+-------------------+--------------------------------+--------------------------------------------+
|``VPORT_RD_CNT``   |``int unsigned``                | Number of vector register read ports       |
+-------------------+--------------------------------+--------------------------------------------+
|``VPORT_RD_W``     |``int unsigned [VPORT_RD_CNT]`` | Width of each of the vector register read  |
|                   |                                | ports (bits, currently all read ports must |
|                   |                                | be ``VREG_W`` bits wide)                   |
+-------------------+--------------------------------+--------------------------------------------+
|``VPORT_WR_CNT``   |``int unsigned``                | Number of vector register write ports      |
+-------------------+--------------------------------+--------------------------------------------+
|``VPORT_WR_W``     |``int unsigned [VPORT_WR_CNT]`` | Width of each of the vector register write |
|                   |                                | ports (bits, currently all write ports     |
|                   |                                | must be ``VREG_W`` bits wide)              |
+-------------------+--------------------------------+--------------------------------------------+

.. note::
   These parameters should normally not be overridden when instantiating the ``vproc_core`` module.
   Instead, a ``vproc_config`` package that provides defaults for these parameters
   should be generated as explained in :doc:`configuration`.

Vector pipeline configuration
(default values taken from configuration package ``vproc_config``):

+-------------------+---------------------------------+-------------------------------------------+
| Name              | Type                            | Description                               |
+===================+=================================+===========================================+
|``PIPE_CNT``       |``int unsigned``                 | Number of vector execution pipelines      |
+-------------------+---------------------------------+-------------------------------------------+
|``PIPE_UNITS``     |``bit [UNIT_CNT-1:0] [PIPE_CNT]``| Vector execution units contained in each  |
|                   |                                 | vector pipeline (for each pipeline the    |
|                   |                                 | bit mask indicates the units it contains) |
+-------------------+---------------------------------+-------------------------------------------+
|``PIPE_W``         |``int unsigned       [PIPE_CNT]``| Operand width of each pipeline (bits)     |
+-------------------+---------------------------------+-------------------------------------------+
|``PIPE_VPORT_CNT`` |``int unsigned       [PIPE_CNT]``| Number of vector register read ports of   |
|                   |                                 | each pipeline                             |
+-------------------+---------------------------------+-------------------------------------------+
|``PIPE_VPORT_IDX`` |``int unsigned       [PIPE_CNT]``| Index of the first vector register read   |
|                   |                                 | port associated with each pipeline        |
+-------------------+---------------------------------+-------------------------------------------+
|``PIPE_VPORT_WR``  |``int unsigned       [PIPE_CNT]``| Index of the vector register write port   |
|                   |                                 | used by each pipeline                     |
+-------------------+---------------------------------+-------------------------------------------+

.. note::
   These parameters should normally not be overridden when instantiating the ``vproc_core`` module.
   Instead, a ``vproc_config`` package that provides defaults for these parameters
   should be generated as explained in :doc:`configuration`.

Unit-specific configuration
(default values taken from configuration package ``vproc_config``):

+-------------------+-------------------------------------+---------------------------------------+
| Name              | Type                                | Description                           |
+===================+=====================================+=======================================+
|``VLSU_QUEUE_SZ``  |``int unsigned``                     | Size of the VLSU's transaction queue  |
|                   |                                     | (limits the number of outstanding     |
|                   |                                     | memory transactions)                  |
+-------------------+-------------------------------------+---------------------------------------+
|``VLSU_FLAGS``     |``bit [vproc_pkg::VLSU_FLAGS_W-1:0]``| Flags for the VLSU's properties       |
+-------------------+-------------------------------------+---------------------------------------+
|``MUL_TYPE``       |``vproc_pkg::mul_type``              | Vector multiplier type                |
+-------------------+-------------------------------------+---------------------------------------+

.. note::
   These parameters should normally not be overridden when instantiating the ``vproc_core`` module.
   Instead, a ``vproc_config`` package that provides defaults for these parameters
   should be generated as explained in :doc:`configuration`.

Miscellaneous configuration
(default values taken from configuration package ``vproc_config``):

+-------------------+------------------------------------+----------------------------------------+
| Name              | Type                               | Description                            |
+===================+====================================+========================================+
|``INSTR_QUEUE_SZ`` |``int unsigned``                    | Size of Vicuna's instruction queue     |
|                   |                                    | (when full, offloading of instructions |
|                   |                                    | is stalled until the first instruction |
|                   |                                    | in the queue can be dispatched)        |
+-------------------+------------------------------------+----------------------------------------+
|``BUF_FLAGS``      |``bit [vproc_pkg::BUF_FLAGS_W-1:0]``| Flags for various optional buffering   |
|                   |                                    | stages (including within the vector    |
|                   |                                    | pipelines)                             |
+-------------------+------------------------------------+----------------------------------------+

.. note::
   These parameters should normally not be overridden when instantiating the ``vproc_core`` module.
   Instead, a ``vproc_config`` package that provides defaults for these parameters
   should be generated as explained in :doc:`configuration`.


.. _core_ports:

Ports
^^^^^

+----------------------+-------+---------+--------------------------------------------------------+
| Name                 | Width |Direction| Description                                            |
+======================+=======+=========+========================================================+
|``clk_i``             | 1     | input   | Clock signal                                           |
+----------------------+-------+---------+--------------------------------------------------------+
|``rst_ni``            | 1     | input   | Active low reset (see parameter ``ASYNC_RESET``)       |
+----------------------+-------+---------+--------------------------------------------------------+
|``issue_*``           | mixed | in/out | Issue interface signals (see `Issue interface`_)        |
+----------------------+-------+---------+--------------------------------------------------------+
|``commit_*``          | mixed | input  | Commit interface signals (see `Commit interface`_)       |
+----------------------+-------+---------+--------------------------------------------------------+
|``vlsu_mem_*``        | mixed | in/out | VLSU memory interface signals (see `VLSU memory interface`_) |
+----------------------+-------+---------+--------------------------------------------------------+
|``result_*``          | mixed | in/out | Result interface signals (see `Result interface`_)       |
+----------------------+-------+---------+--------------------------------------------------------+
|``pending_load_o``    | 1     | output  | Indicates that there is a pending vector load          |
+----------------------+-------+---------+--------------------------------------------------------+
|``pending_store_o``   | 1     | output  | Indicates that there is a pending vector store         |
+----------------------+-------+---------+--------------------------------------------------------+
|``csr_vtype_o``       | 32    | output  | *Deprecated* Content of the ``vtype`` CSR              |
+----------------------+-------+---------+--------------------------------------------------------+
|``csr_vl_o``          | 32    | output  | *Deprecated* Content of the ``vl`` CSR                 |
+----------------------+-------+---------+--------------------------------------------------------+
|``csr_vlenb_o``       | 32    | output  | *Deprecated* Content of the ``vlenb`` CSR              |
+----------------------+-------+---------+--------------------------------------------------------+
|``csr_vstart_o``      | 32    | output  | *Deprecated* Content of the ``vstart`` CSR             |
+----------------------+-------+---------+--------------------------------------------------------+
|``csr_vstart_i``      | 32    | input   | *Deprecated* Data for setting the ``vstart`` CSR       |
+----------------------+-------+---------+--------------------------------------------------------+
|``csr_vstart_set_i``  | 1     | input   | *Deprecated* Write enable setting the ``vstart`` CSR   |
+----------------------+-------+---------+--------------------------------------------------------+
|``csr_vxrm_o``        | 2     | output  | *Deprecated* Content of the ``vxrm`` CSR               |
+----------------------+-------+---------+--------------------------------------------------------+
|``csr_vxrm_i``        | 2     | input   | *Deprecated* Data for setting the ``vxrm`` CSR         |
+----------------------+-------+---------+--------------------------------------------------------+
|``csr_vxrm_set_i``    | 1     | input   | *Deprecated* Write enable setting the ``vxrm`` CSR     |
+----------------------+-------+---------+--------------------------------------------------------+
|``csr_vxsat_o``       | 1     | output  | *Deprecated* Content of the ``vxsat`` CSR              |
+----------------------+-------+---------+--------------------------------------------------------+
|``csr_vxsat_i``       | 1     | input   | *Deprecated* Data for setting the ``vxsat`` CSR        |
+----------------------+-------+---------+--------------------------------------------------------+
|``csr_vxsat_set_i``   | 1     | input   | *Deprecated* Write enable setting the ``vxrm`` CSR     |
+----------------------+-------+---------+--------------------------------------------------------+
|``pend_vreg_wr_map_o``| 32    | output  | *Debug* Map of pending vector register writes          |
+----------------------+-------+---------+--------------------------------------------------------+

.. _Issue interface:

Issue interface
"""""""""""""""
Direct coupling issue/accept handshake with the main core.

.. _Commit interface:

Commit interface
""""""""""""""""
Commit/kill signaling for issued instructions.

.. _VLSU memory interface:

VLSU memory interface
"""""""""""""""""""""
Vector load/store memory request/response signaling.

.. _Result interface:

Result interface
""""""""""""""""
Result writeback and exception reporting.

The ``clk_i`` and ``rst_ni`` ports are the clock and active-low reset inputs, respectively.
The reset may be either synchronous (the default) or asynchronous.
When using an asynchronous reset the parameter ``ASYNC_RESET`` must be set to ``1'b1``.

Vicuna directly couples to the main core using explicit issue/commit/result
signals and a dedicated VLSU memory interface.

The VLSU memory interface exposes Vicuna's memory requests directly.
If these ports are connected to a shared arbiter, the arbiter must enforce the
same ordering rules as for main-core accesses.

If Vicuna's ports are directly hooked up to a memory arbiter,
than that arbiter must hold back memory requests by the main core
while there are pending vector loads and stores,
in order to ensure data consistency.
The output ports ``pending_load_o`` and ``pending_store_o`` indicate
whether a vector load or store is currently in progress, respectively.
Data requests of the main core must be paused according to the following table:

+------------------+-------------------+----------------------------------------------------------+
|``pending_load_o``|``pending_store_o``| Rule                                                     |
+==================+===================+==========================================================+
| 0                | 0                 | Main core may read and write data                        |
+------------------+-------------------+----------------------------------------------------------+
| 1                | 0                 | Main core may read data, but data writes are held back   |
+------------------+-------------------+----------------------------------------------------------+
| X                | 1                 | Both data reads and writes from the main core must be    |
|                  |                   | held back                                                |
+------------------+-------------------+----------------------------------------------------------+

If Vicuna's memory interface is connected through a shared arbiter,
``pending_load_o`` and ``pending_store_o`` can be used to throttle scalar data
requests as shown above.

The ``csr_*`` ports are a deprecated way of accessing the seven vector CSRs,
as defined in the `RISC-V V extension specification <https://github.com/riscv/riscv-v-spec>`__.
Note that the ``vcsr`` CSR is just a concatenation of ``vxsat`` and ``vxrm``,
which is why no dedicated ports for that CSR are provided.
The ``csr_*_o`` ports can be used to read the content of any of the vector CSRs.
The ``csr_*_set_i`` and ``csr_*_i`` port pairs can be used to overwrite the content
of the four read/write CSRs.
The ``csr_*_set_i`` ports are used as active-high write enable signals,
which move the data supplied on the associated ``csr_*_i`` port into the corresponding CSR.

The ``csr_*`` ports deprecated and will be removed in the future.
The vector CSRs should be accessed via the main core using regular CSR instructions.
Designs should leave the ``csr_*_o`` ports unconnected and drive the ``csr_*_i`` ports with ``'0``.

The ``pend_vreg_wr_map_o`` output port is used for debug purposes
to keep track of pending vector register writes within Vicuna.
Design should leave that port unconnected.


Integrate Vicuna combined with a main core
------------------------------------------

Instantiate the ``vproc_top`` module using the following instantiation template:

.. code-block:: systemverilog

   vproc_top #(
       .MEM_W              (                       ),
       .VMEM_W             (                       ),
       .ICACHE_SZ          (                       ),
       .ICACHE_LINE_W      (                       ),
       .DCACHE_SZ          (                       ),
       .DCACHE_LINE_W      (                       )
   ) vproc (
       .clk_i              (                       ),
       .rst_ni             (                       ),
       .mem_req_o          (                       ),
       .mem_addr_o         (                       ),
       .mem_we_o           (                       ),
       .mem_be_o           (                       ),
       .mem_wdata_o        (                       ),
       .mem_rvalid_i       (                       ),
       .mem_err_i          (                       ),
       .mem_rdata_i        (                       ),
       .pend_vreg_wr_map_o (                       )
   );


.. _top_parameters:

Parameters
^^^^^^^^^^

+-----------------+----------------+----------------+---------------------------------------------+
| Name            | Type           | Default        | Description                                 |
+=================+================+================+=============================================+
|``MEM_W``        |``int unsigned``|``32``          | Memory bus width (bits)                     |
+-----------------+----------------+----------------+---------------------------------------------+
|``VMEM_W``       |``int unsigned``|``32``          | Vector memory interface width (bits)        |
+-----------------+----------------+----------------+---------------------------------------------+
|``VREG_TYPE``    |``vreg_type``   |``VREG_GENERIC``| Vector register file type (defined in       |
|                 |                |                | ``vproc_pkg``, see :ref:`the parameters of  |
|                 |                |                | the core module <core_parameters_config>`)  |
+-----------------+----------------+----------------+---------------------------------------------+
|``MUL_TYPE``     |``mul_type``    |``MUL_GENERIC`` | Vector multiplier type (defined in          |
|                 |                |                | ``vproc_pkg``, see :ref:`the parameters of  |
|                 |                |                | the core module <core_parameters_config>`)  |
+-----------------+----------------+----------------+---------------------------------------------+
|``ICACHE_SZ``    |``int unsigned``|``0``           | Instruction cache size (bytes,              |
|                 |                |                | 0 = no instruction cache                    |
+-----------------+----------------+----------------+---------------------------------------------+
|``ICACHE_LINE_W``|``int unsigned``|``128``         | Line width of the instruction cache (bits)  |
+-----------------+----------------+----------------+---------------------------------------------+
|``DCACHE_SZ``    |``int unsigned``|``0``           | Data cache size (bytes, 0 = no data cache)  |
+-----------------+----------------+----------------+---------------------------------------------+
|``DCACHE_LINE_W``|``int unsigned``|``512``         | Line width of the data cache (bits)         |
+-----------------+----------------+----------------+---------------------------------------------+


.. _top_ports:

Ports
^^^^^

+----------------------+-------+---------+--------------------------------------------------------+
| Name                 | Width |Direction| Description                                            |
+======================+=======+=========+========================================================+
|``clk_i``             | 1     | input   | Clock signal                                           |
+----------------------+-------+---------+--------------------------------------------------------+
|``rst_ni``            | 1     | input   | Active low reset                                       |
+----------------------+-------+---------+--------------------------------------------------------+
|``mem_req_o``         | 1     | output  | Memory request valid signal (high for one cycle)       |
+----------------------+-------+---------+--------------------------------------------------------+
|``mem_addr_o``        | 32    | output  | Memory address (word aligned, valid when ``mem_req_o`` |
|                      |       |         | is high)                                               |
+----------------------+-------+---------+--------------------------------------------------------+
|``mem_we_o``          | 1     | output  | Memory write enable (high for writes, low for reads,   |
|                      |       |         | (valid when ``mem_req_o`` is high)                     |
+----------------------+-------+---------+--------------------------------------------------------+
|``mem_be_o``          |MEM_W/8| output  | Memory byte enable for writes  (valid when             |
|                      |       |         | ``mem_req_o`` is high)                                 |
+----------------------+-------+---------+--------------------------------------------------------+
|``mem_wdata_o``       | MEM_W | output  | Memory write data (valid when ``mem_req_o`` is high)   |
+----------------------+-------+---------+--------------------------------------------------------+
|``mem_rvalid_i``      | 1     | input   | Memory read data valid signal (high for one cycle)     |
+----------------------+-------+---------+--------------------------------------------------------+
|``mem_err_i``         | 1     | input   | Memory error (high on error, valid when                |
|                      |       |         | ``mem_rvalid_i`` is high)                              |
+----------------------+-------+---------+--------------------------------------------------------+
|``mem_rdata_i``       | MEM_W | input   | Memory read data (valid when ``mem_rvalid_i`` is high) |
+----------------------+-------+---------+--------------------------------------------------------+
|``pend_vreg_wr_map_o``| 32    | output  | *Debug* Pending vector register writes map             |
+----------------------+-------+---------+--------------------------------------------------------+
