#include <iostream>
#include <vector>
#include <cstdint>

// This file is a scanner fixture. It intentionally uses XRT-style API names.
// It does not need to compile on machines without XRT headers.

#include "xrt/xrt_device.h"
#include "xrt/xrt_bo.h"
#include "xrt/xrt_kernel.h"

int main(int argc, char** argv) {
    const int n = 1024;
    std::vector<int> in1(n, 1);
    std::vector<int> in2(n, 2);
    std::vector<int> out(n, 0);

    auto device = xrt::device(0);
    auto uuid = device.load_xclbin("vadd.xclbin");
    auto kernel = xrt::kernel(device, uuid, "vadd");

    auto bo_in1 = xrt::bo(device, n * sizeof(int), kernel.group_id(0));
    auto bo_in2 = xrt::bo(device, n * sizeof(int), kernel.group_id(1));
    auto bo_out = xrt::bo(device, n * sizeof(int), kernel.group_id(2));

    bo_in1.write(in1.data());
    bo_in2.write(in2.data());

    bo_in1.sync(XCL_BO_SYNC_BO_TO_DEVICE);
    bo_in2.sync(XCL_BO_SYNC_BO_TO_DEVICE);

    auto run = kernel(bo_in1, bo_in2, bo_out, n);
    run.wait();

    bo_out.sync(XCL_BO_SYNC_BO_FROM_DEVICE);
    bo_out.read(out.data());

    for (int i = 0; i < n; ++i) {
        if (out[i] != 3) {
            std::cerr << "Mismatch at " << i << std::endl;
            return 1;
        }
    }

    std::cout << "PASS" << std::endl;
    return 0;
}
