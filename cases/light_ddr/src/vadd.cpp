#include <stdint.h>

extern "C" {
void vadd(const int* in1, const int* in2, int* out, int n) {
#pragma HLS INTERFACE m_axi port=in1 offset=slave bundle=gmem0
#pragma HLS INTERFACE m_axi port=in2 offset=slave bundle=gmem1
#pragma HLS INTERFACE m_axi port=out offset=slave bundle=gmem2
#pragma HLS INTERFACE s_axilite port=in1 bundle=control
#pragma HLS INTERFACE s_axilite port=in2 bundle=control
#pragma HLS INTERFACE s_axilite port=out bundle=control
#pragma HLS INTERFACE s_axilite port=n bundle=control
#pragma HLS INTERFACE s_axilite port=return bundle=control

    for (int i = 0; i < n; ++i) {
#pragma HLS PIPELINE II=1
        out[i] = in1[i] + in2[i];
    }
}
}
