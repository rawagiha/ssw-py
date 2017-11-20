
#cython: boundscheck=False, wraparound=False
from cpython.mem cimport PyMem_Malloc, PyMem_Realloc, PyMem_Free
from cython.operator cimport postincrement as inc
from libc.string cimport memcpy
from libc.stdio cimport printf
from libc.stdint cimport int32_t, uint32_t, uint16_t, int8_t, uint8_t
from libc.stdlib cimport malloc, free

cimport c_util

"""
What is a CIGAR?
http://genome.sph.umich.edu/wiki/SAM#What_is_a_CIGAR.3F
"""

cdef extern from "str_util.h":
    void dnaToInt8(const char*, int8_t*, int32_t)
    void ssw_write_cigar(const s_align*)
    void ssw_writer(const s_align*, const char*, const char*)

cdef extern from "ssw.h":
    # leave out a few members
    ctypedef struct s_profile:
        const int8_t* read
        const int8_t* mat
        int32_t readLen
        int32_t n
        uint8_t bias

    ctypedef struct s_align:
        uint16_t score1
        uint16_t score2
        int32_t ref_begin1
        int32_t ref_end1
        int32_t read_begin1
        int32_t read_end1
        int32_t ref_end2
        uint32_t* cigar
        int32_t cigarLen

    s_profile* ssw_init(const int8_t*, const int32_t, const int8_t*, const int32_t, const int8_t)
    void init_destroy (s_profile*)
    s_align* ssw_align (const s_profile*, const int8_t*, int32_t, const uint8_t, const uint8_t, const uint8_t, const uint16_t, const int32_t, const int32_t)
    void align_destroy (s_align*)
    char cigar_int_to_op (uint32_t)
    uint32_t cigar_int_to_len(uint32_t)
    uint32_t to_cigar_int(uint32_t, char)


cdef class SSW:

    cdef int8_t* score_matrix
    cdef s_profile* profile

    cdef object read
    cdef int8_t* read_arr
    cdef Py_ssize_t read_length

    cdef object reference
    cdef int8_t* ref_arr
    cdef Py_ssize_t ref_length

    def __cinit__(self, int match_score=2,
                        int mismatch_penalty=2):
        self.score_matrix = NULL
        self.profile = NULL
        self.read_arr = NULL
        self.ref_arr = NULL
    # end def

    def __init__(self,  int match_score=2,
                        int mismatch_penalty=2):
        self.score_matrix = <int8_t*> PyMem_Malloc(25*sizeof(int8_t))
        self.buildDNAScoreMatrix(   <uint8_t>match_score,
                                    <uint8_t> mismatch_penalty,
                                    self.score_matrix)
        self.read = None
        self.reference = None
    # end def

    def __dealloc__(self):
        PyMem_Free(self.score_matrix)

        if self.profile != NULL:
            init_destroy(self.profile)
            self.profile = NULL

        if self.read_arr != NULL:
            PyMem_Free(self.read_arr)

        if self.ref_arr != NULL:
            PyMem_Free(self.ref_arr)
    # end def

    cdef int printResult_c(self, s_align* result, Py_ssize_t start_idx) except -1:
        cdef const char* read_cstr
        cdef Py_ssize_t read_length, ref_length
        cdef const char* ref_cstr

        print(self.read)
        if result != NULL:
            read_cstr = c_util.obj_to_cstr_len(self.read, &read_length)
            ref_cstr = c_util.obj_to_cstr_len(self.reference[start_idx:], &ref_length)

            ssw_write_cigar(result)
            ssw_writer(result, ref_cstr, read_cstr)
        return 0
    # end def


    def printResult(self, result, start_idx=0):
        """ rebuild a s_align struct from a result dictionary
        so as to be able to call ssw terminal print functions
        """
        cdef uint32_t* cigar_array = NULL
        cdef s_align *res_align = NULL
        cdef char letter
        cdef uint32_t length

        cdef Py_ssize_t i, j

        try:
            res_align = <s_align*> PyMem_Malloc(sizeof(s_align))
            if res_align == NULL:
                raise MemoryError('Out of Memory')
            cigar = result.get('CIGAR')
            if cigar is not None:
                cigar_array = <uint32_t*> PyMem_Malloc(len(cigar)//2*sizeof(uint32_t))
                if cigar_array == NULL:
                    raise MemoryError('Out of Memory')
                j = 0
                for i in range(0, len(cigar), 2):
                    length = int(cigar[i])
                    letter = ord(cigar[i+1])
                    cigar_array[j] = to_cigar_int(length, letter)
                    j += 1
                res_align.cigar = cigar_array
                res_align.cigarLen = len(cigar)//2
            else:
                res_align.cigar = NULL
            res_align.score1 = result["optimal_score"]
            res_align.score2 = result["sub-optimal_score"]
            res_align.ref_begin1 = result["target_begin"]
            res_align.ref_end1 = result["target_end"]
            res_align.read_begin1 = result["query_begin"]
            res_align.read_end1 = result["query_end"]

            self.printResult_c(res_align, start_idx)
        finally:
            if cigar is not None:
                PyMem_Free(cigar_array)
            PyMem_Free(res_align)
    # end def

    def setRead(self, object read):
        """
        """
        cdef Py_ssize_t read_length
        cdef const char* read_cstr = c_util.obj_to_cstr_len(read, &read_length)
        cdef int8_t* read_arr = <int8_t*> PyMem_Malloc(read_length*sizeof(char))

        if self.profile != NULL:
            init_destroy(self.profile)
            self.profile = NULL
        if self.read_arr != NULL:
            PyMem_Free(self.read_arr)
            self.read_arr = NULL

        self.read = read
        self.read_arr = read_arr
        self.read_length = read_length
        dnaToInt8(read_cstr, read_arr, read_length)

        self.profile = ssw_init(read_arr,
                                <int32_t> read_length,
                                self.score_matrix,
                                5,
                                2 # don't know best score size
                                )
    # end def

    def setReference(self, object reference):
        cdef Py_ssize_t ref_length
        cdef const char* ref_cstr = c_util.obj_to_cstr_len(reference, &ref_length)
        cdef int8_t* ref_arr = <int8_t*> PyMem_Malloc(ref_length*sizeof(char))
        dnaToInt8(ref_cstr, ref_arr, ref_length)
        self.reference = reference
        if self.ref_arr != NULL:
            PyMem_Free(self.ref_arr)
            self.ref_arr = NULL
        self.ref_arr = ref_arr
        self.ref_length = ref_length
    # end def

    cdef s_align* align_c(self, int gap_open, int gap_extension, Py_ssize_t start_idx, int32_t mod_ref_length) except NULL:
        """
        """
        cdef Py_ssize_t read_length
        cdef const char* read_cstr = c_util.obj_to_cstr_len(self.read, &read_length)
        cdef s_align* result = NULL
        cdef int32_t mask_len = read_length / 2

        mask_len = 15 if mask_len < 15 else mask_len

        if self.profile != NULL:
            result = ssw_align ( self.profile,
                                &self.ref_arr[start_idx],
                                self.ref_length - mod_ref_length,
                                gap_open,
                                gap_extension,
                                1, 0, 0, mask_len)
        else:
            raise ValueError("Must set profile first")
        if result == NULL:
            raise ValueError("Problem Running alignment, see stdout")
        return result
    # end def

    def align(self, int gap_open=3, int gap_extension=1, Py_ssize_t start_idx=0, Py_ssize_t end_idx=0):
        """ Align a read to the reference with optional index offseting

        returns a dictionary no matter what as align_c can't return
        NULL

        Kwargs:
            gap_open (int):         penalty for gap_open. default 3
            gap_extension (int):    penalty for gap_extension. default 1
            start_idx (Py_ssize_t): index to start search. default 0
            end_idx (Py_ssize_t):   index to end search (trying to avoid a target region). 
                                    default 0 means use whole reference length

        Returns:
            dict    with keys   `CIGAR`,        <for depicting alignment>
                                `optimal_score`, 
                                `sub-optimal_score`,
                                `target_begin`, <index into reference>
                                `target_end`,   <index into reference>
                                `query_begin`,  <index into read>
                                `query_end`     <index into read>

        Raises
            ValueError
        """
        cdef Py_ssize_t c
        cdef char letter
        cdef int letter_int
        cdef uint32_t length
        cdef int32_t search_length
        cdef Py_ssize_t end_idx_final
        
        if start_idx < 0 or end_idx < 0:
            raise ValueError("negative indexing not supported")
        if end_idx > self.ref_length or start_idx > self.ref_length:
            err = "start_idx: {} or end_idx: {} can't be greater than ref_length: {}".format(
                                                start_idx, 
                                                end_idx, 
                                                self.ref_length)
            raise ValueError(err)
        if end_idx == 0:
            end_idx_final = self.ref_length
        else:
            end_idx_final = end_idx
        search_length = end_idx_final - start_idx

        cigar = None

        if self.reference is None:
            raise ValueError("call setReference first")

        cdef s_align* result =  self.align_c(gap_open, gap_extension, start_idx, search_length)
        if result.cigar != NULL:
            cigar = ""
            for c in range(result.cigarLen):
                letter = cigar_int_to_op(result.cigar[c])
                letter_int = letter
                length = cigar_int_to_len(result.cigar[c])
                cigar += "%d%s" % (<int>length, chr(letter_int))
        out = {
                "CIGAR":   cigar,
                "optimal_score": result.score1,
                "sub-optimal_score": result.score2,
                "target_begin": result.ref_begin1,
                "target_end": result.ref_end1,
                "query_begin": result.read_begin1,
                "query_end": result.read_end1
        }
        #print("RAW BEGIN")
        #self.printResult_c(result)
        #print("RAW END")
        align_destroy(result)
        return out
    # end def

    cdef int buildDNAScoreMatrix(self,  const uint8_t match_score,
                                    const uint8_t mismatch_penalty,
                                    int8_t* matrix) except -1:
        """
        mismatch_penalty should be positive

        The score matrix looks like
                            A,  C,  G,  T,  N
        score_matrix  = {   2, -2, -2, -2,  0, // A
                           -2,  2, -2, -2,  0, // C
                           -2, -2,  2, -2,  0, // G
                           -2, -2, -2,  2,  0, // T
                            0,  0,  0,  0,  0  // N
                        }
        """
        cdef Py_ssize_t i, j
        cdef Py_ssize_t idx = 0;
        for i in range(4):
            for j in range(4):
                if i == j:
                    matrix[idx] =  <int8_t> match_score
                else:
                    matrix[idx] = <int8_t> (-mismatch_penalty)
                inc(idx)
            matrix[idx] = 0;
            inc(idx)
        for i in range(5):
            matrix[inc(idx)] = 0
        return 0
    # end def
# end class
