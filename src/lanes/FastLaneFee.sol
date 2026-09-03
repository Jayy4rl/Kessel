// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";


library FastLaneFee {
    
    uint256 internal constant K_DENOMINATOR = 1 gwei;

    uint256 internal constant FEE_DENOMINATOR = 1_000_000;

    uint256 internal constant Q96 = 1 << 96;

   
    uint256 internal constant MAX_CONVERTIBLE_PRICE_X96 = type(uint256).max >> 33;

   
    function priorityFeePerGas() internal view returns (uint256) {
        uint256 gasPrice = tx.gasprice;
        uint256 baseFee = block.basefee;
        unchecked {
            return gasPrice > baseFee ? gasPrice - baseFee : 0;
        }
    }

    
    function fee(
        uint24 fBase,
        uint256 k,
        uint256 priorityFee,
        uint24 maxFastFee
    ) internal pure returns (uint24) {
        if (k == 0 || priorityFee == 0) return fBase < maxFastFee ? fBase : maxFastFee;

        if (priorityFee > type(uint256).max / k) return maxFastFee;

        uint256 tax = (k * priorityFee) / K_DENOMINATOR;
        uint256 total = uint256(fBase) + tax;

        
        return total >= maxFastFee ? maxFastFee : uint24(total);
    }

    
    function feeBySize(
        uint24 fBase,
        uint256 kGas,
        uint256 priorityFee,
        uint256 sizeWei,
        uint24 maxFastFee
    ) internal pure returns (uint24) {
        if (kGas == 0 || priorityFee == 0) return fBase < maxFastFee ? fBase : maxFastFee;

        
        if (sizeWei == 0) return maxFastFee;

        if (priorityFee > type(uint256).max / kGas) return maxFastFee;
        uint256 taxWei = kGas * priorityFee;

        if (taxWei > type(uint256).max / FEE_DENOMINATOR) return maxFastFee;
        uint256 tax = (taxWei * FEE_DENOMINATOR) / sizeWei;

        uint256 total = uint256(fBase) + tax;

        
        return total >= maxFastFee ? maxFastFee : uint24(total);
    }

   
    function sizeInGasToken(
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceX96,
        bool gasTokenIsCurrency0
    ) internal pure returns (bool ok, uint256 sizeWei) {
        if (sqrtPriceX96 == 0) return (false, 0);

        uint256 amount = amountSpecified < 0 ? uint256(-amountSpecified) : uint256(amountSpecified);
        if (amount == 0) return (true, 0);
        if (amount > type(uint128).max) return (false, 0);

        
        bool specifiedIsCurrency0 = (amountSpecified < 0) == zeroForOne;

        if (specifiedIsCurrency0 == gasTokenIsCurrency0) return (true, amount);

        
        uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96);
        if (priceX96 == 0 || priceX96 > MAX_CONVERTIBLE_PRICE_X96) return (false, 0);

        if (specifiedIsCurrency0) {
            return (true, FullMath.mulDiv(amount, priceX96, Q96));
        }
       
        return (true, FullMath.mulDiv(amount, Q96, priceX96));
    }

    
    function premium(
        uint24 feeCharged,
        uint24 fBase
    ) internal pure returns (uint24) {
        unchecked {
            return feeCharged > fBase ? feeCharged - fBase : 0;
        }
    }
}
