// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @notice Trimmed interface to the Pendle Router V4 functions we use.
///         Reference deployment (Base): 0x888888888889758F76e7103c6CbF23ABbF58F946
///         Verify against canonical Pendle V4 source at deploy time.
interface IPendleRouterV4 {
    struct ApproxParams {
        uint256 guessMin;
        uint256 guessMax;
        uint256 guessOffchain;
        uint256 maxIteration;
        uint256 eps;
    }

    struct SwapData {
        // Pendle's SwapData struct — kept opaque here; pass empty for direct USDC entry
        uint8 swapType;
        address extRouter;
        bytes extCalldata;
        bool needScale;
    }

    struct TokenInput {
        address tokenIn;       // we use USDC
        uint256 netTokenIn;
        address tokenMintSy;   // we use USDC (no aggregator path)
        address pendleSwap;    // address(0)
        SwapData swapData;     // empty
    }

    struct TokenOutput {
        address tokenOut;
        uint256 minTokenOut;
        address tokenRedeemSy;
        address pendleSwap;
        SwapData swapData;
    }

    struct LimitOrderData {
        address limitRouter;
        uint256 epsSkipMarket;
        // Pendle limit order fields — pass empty for v1
        bytes normalFills;
        bytes flashFills;
        bytes optData;
    }

    function swapExactTokenForYt(
        address receiver,
        address market,
        uint256 minYtOut,
        ApproxParams calldata guessYtOut,
        TokenInput calldata input,
        LimitOrderData calldata limit
    ) external returns (uint256 netYtOut, uint256 netSyFee, uint256 netSyInterm);

    function swapExactYtForToken(
        address receiver,
        address market,
        uint256 exactYtIn,
        TokenOutput calldata output,
        LimitOrderData calldata limit
    ) external returns (uint256 netTokenOut, uint256 netSyFee, uint256 netSyInterm);

    function redeemPyToToken(
        address receiver,
        address yt,
        uint256 netPyIn,
        TokenOutput calldata output
    ) external returns (uint256 netTokenOut, uint256 netSyInterm);
}
