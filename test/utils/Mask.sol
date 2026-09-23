// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
import {ICovenRouter} from "../../src/interfaces/ICovenRouter.sol";

/// Builds mask windows from a list of PUSH32 immediate offsets, which is what the
/// diff-based helpers in the test suite produce.
library Mask {
    function windows(uint16[] memory offsets) internal pure returns (ICovenRouter.MaskWindow[] memory out) {
        out = new ICovenRouter.MaskWindow[](offsets.length);
        for (uint256 i; i < offsets.length; ++i) {
            out[i] = ICovenRouter.MaskWindow({offset: offsets[i], length: 32});
        }
    }

    function none() internal pure returns (ICovenRouter.MaskWindow[] memory) {
        return new ICovenRouter.MaskWindow[](0);
    }

    function one(uint16 offset, uint16 length) internal pure returns (ICovenRouter.MaskWindow[] memory out) {
        out = new ICovenRouter.MaskWindow[](1);
        out[0] = ICovenRouter.MaskWindow({offset: offset, length: length});
    }
}
