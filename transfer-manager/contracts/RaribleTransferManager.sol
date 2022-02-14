// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;
pragma abicoder v2;

import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";
import "@rarible/lib-asset/contracts/LibAsset.sol";
import "@rarible/royalties/contracts/IRoyaltiesProvider.sol";
import "@rarible/lazy-mint/contracts/erc-721/LibERC721LazyMint.sol";
import "@rarible/lazy-mint/contracts/erc-1155/LibERC1155LazyMint.sol";
import "@rarible/libraries/contracts/LibFill.sol";
import "@rarible/libraries/contracts/LibFeeSide.sol";
import "@rarible/libraries/contracts/BpLibrary.sol";
import "@rarible/libraries/contracts/LibDeal.sol";
import "@rarible/exchange-interfaces/contracts/ITransferManager.sol";
import "./TransferExecutor.sol";
import "@rarible/exchange-interfaces/contracts/IWETH.sol";
import "@rarible/transfer-proxy/contracts/roles/OperatorRole.sol";

contract RaribleTransferManager is TransferExecutor, ITransferManager, OperatorRole {
    using BpLibrary for uint;
    using SafeMathUpgradeable for uint;
    using LibTransfer for address;

    IRoyaltiesProvider public royaltiesRegistry;

    address public defaultFeeReceiver;
    mapping(address => address) public feeReceivers;

    function __RaribleTransferManager_init(
        address newDefaultFeeReceiver,
        IRoyaltiesProvider newRoyaltiesProvider,
        INftTransferProxy transferProxy,
        IERC20TransferProxy erc20TransferProxy
    ) external initializer {
        __Context_init_unchained();
        __Ownable_init_unchained();
        __TransferExecutor_init_unchained(transferProxy, erc20TransferProxy);
        __RaribleTransferManager_init_unchained(newDefaultFeeReceiver, newRoyaltiesProvider);
    }

    function __RaribleTransferManager_init_unchained(
        address newDefaultFeeReceiver,
        IRoyaltiesProvider newRoyaltiesProvider
    ) internal initializer {
        defaultFeeReceiver = newDefaultFeeReceiver;
        royaltiesRegistry = newRoyaltiesProvider;
    }

    function setRoyaltiesRegistry(IRoyaltiesProvider newRoyaltiesRegistry) external onlyOwner {
        royaltiesRegistry = newRoyaltiesRegistry;
    }

    function setDefaultFeeReceiver(address payable newDefaultFeeReceiver) external onlyOwner {
        defaultFeeReceiver = newDefaultFeeReceiver;
    }

    function setFeeReceiver(address token, address wallet) external onlyOwner {
        feeReceivers[token] = wallet;
    }

    function getFeeReceiver(address token) internal view returns (address) {
        address wallet = feeReceivers[token];
        if (wallet != address(0)) {
            return wallet;
        }
        return defaultFeeReceiver;
    }

    function executeTransfer(
        LibAsset.Asset memory asset,
        address from,
        address to,
        bytes4 transferDirection,
        bytes4 transferType
    ) override external onlyOperator {
        require(asset.assetType.assetClass != LibAsset.ETH_ASSET_CLASS, "ETH not supported");
        transfer(asset, from, to, transferDirection, transferType);
    }

    function doTransfers(
        LibDeal.DealSide memory left,
        LibDeal.DealSide memory right,
        LibFeeSide.FeeSide feeSide,
        address initialSender
    ) override payable external onlyOperator returns (uint totalLeftValue, uint totalRightValue) {
        totalLeftValue = left.value;
        totalRightValue = right.value;
        /*fix assetClass, need for send back change when one side is ETH_ASSET_CLASS*/
        bytes4 leftAssetClass = left.assetType.assetClass;
        bytes4 rightAssetClass = right.assetType.assetClass;

        if (feeSide == LibFeeSide.FeeSide.LEFT) {
            totalLeftValue = doTransfersWithFees(left, right, TO_TAKER);
            transferPayouts(right.assetType, right.value, right.sideAddress, left.payouts, TO_MAKER);
        } else if (feeSide == LibFeeSide.FeeSide.RIGHT) {
            totalRightValue = doTransfersWithFees(right, left, TO_MAKER);
            transferPayouts(left.assetType, left.value, left.sideAddress, right.payouts, TO_TAKER);
        } else {
            transferPayouts(left.assetType, left.value, left.sideAddress, right.payouts, TO_TAKER);
            transferPayouts(right.assetType, right.value, right.sideAddress, left.payouts, TO_MAKER);
        }

        /*if on of assetClass == ETH, need to transfer ETH to RaribleTransferManager contract before run method doTransfers*/
        if (leftAssetClass == LibAsset.ETH_ASSET_CLASS) {
            require(rightAssetClass != LibAsset.ETH_ASSET_CLASS, "try transfer eth<->eth");
            require(msg.value >= totalLeftValue, "not enough eth");
            uint256 change = msg.value.sub(totalLeftValue);
            if (change > 0) {
                initialSender.transferEth(change);
            }
        } else if (rightAssetClass == LibAsset.ETH_ASSET_CLASS) {
            require(msg.value >= totalRightValue, "not enough eth");
            uint256 change = msg.value.sub(totalRightValue);
            if (change > 0) {
                initialSender.transferEth(change);
            }
        }
    }

    function doTransfersWithFees(
        LibDeal.DealSide memory calculateSide,
        LibDeal.DealSide memory nftSide,
        bytes4 transferDirection
    ) internal returns (uint totalAmount) {
        totalAmount = calculateTotalAmount(calculateSide.value, calculateSide.protocolFee, calculateSide.originFees);
        LibDeal.DealSide memory newPaymentSide = unwrapWETH(calculateSide, totalAmount, transferDirection);
        uint rest = transferProtocolFee(totalAmount, newPaymentSide.value, newPaymentSide.sideAddress, newPaymentSide.protocolFee, nftSide.protocolFee, newPaymentSide.assetType, transferDirection);
        rest = transferRoyalties(newPaymentSide.assetType, nftSide.assetType, rest, newPaymentSide.value, newPaymentSide.sideAddress, transferDirection);
        (rest,) = transferFees(newPaymentSide.assetType, rest, newPaymentSide.value, newPaymentSide.originFees, newPaymentSide.sideAddress, transferDirection, ORIGIN);
        (rest,) = transferFees(newPaymentSide.assetType, rest, newPaymentSide.value, nftSide.originFees, newPaymentSide.sideAddress, transferDirection, ORIGIN);
        transferPayouts(newPaymentSide.assetType, rest, newPaymentSide.sideAddress, nftSide.payouts, transferDirection);
    }

    function unwrapWETH(LibDeal.DealSide memory paymentSide, uint totalAmount, bytes4 transferDirection) internal returns (LibDeal.DealSide memory) {
        if (paymentSide.assetType.assetClass != LibAsset.WETH_UNWRAP) {
            return paymentSide;
        }
        /*for transfer WETH to RaribleTransferManager contract use ERC20TransferProxy*/
        LibAsset.AssetType memory transferWETH = paymentSide.assetType;
        transferWETH.assetClass = LibAsset.ERC20_ASSET_CLASS;
        transfer(LibAsset.Asset(transferWETH, totalAmount), paymentSide.sideAddress, address(this), transferDirection, PROTOCOL);
        (address token) = abi.decode(transferWETH.data, (address));
        /*withdraw ETH to RaribleTransferManager contract*/
        IWETH(token).withdraw(totalAmount);
        LibDeal.DealSide memory newPaymentSide = paymentSide;
        newPaymentSide.assetType.assetClass = LibAsset.ETH_ASSET_CLASS;
        return newPaymentSide;
    }

    function transferProtocolFee(
        uint totalAmount,
        uint amount,
        address from,
        uint feeSideProtocolFee,
        uint nftSideProtocolFee,
        LibAsset.AssetType memory matchCalculate,
        bytes4 transferDirection
    ) internal returns (uint) {
        (uint rest, uint fee) = subFeeInBp(totalAmount, amount, feeSideProtocolFee + nftSideProtocolFee);
        if (fee > 0) {
            address tokenAddress = address(0);
            if (matchCalculate.assetClass == LibAsset.ERC20_ASSET_CLASS) {
                tokenAddress = abi.decode(matchCalculate.data, (address));
            } else if (matchCalculate.assetClass == LibAsset.ERC1155_ASSET_CLASS) {
                uint tokenId;
                (tokenAddress, tokenId) = abi.decode(matchCalculate.data, (address, uint));
            }
            transfer(LibAsset.Asset(matchCalculate, fee), from, getFeeReceiver(tokenAddress), transferDirection, PROTOCOL);
        }
        return rest;
    }

    function transferRoyalties(
        LibAsset.AssetType memory matchCalculate,
        LibAsset.AssetType memory matchNft,
        uint rest,
        uint amount,
        address from,
        bytes4 transferDirection
    ) internal returns (uint) {
        LibPart.Part[] memory fees = getRoyaltiesByAssetType(matchNft);

        (uint result, uint totalRoyalties) = transferFees(matchCalculate, rest, amount, fees, from, transferDirection, ROYALTY);
        require(totalRoyalties <= 5000, "Royalties are too high (>50%)");
        return result;
    }

    function getRoyaltiesByAssetType(LibAsset.AssetType memory matchNft) internal returns (LibPart.Part[] memory) {
        if (matchNft.assetClass == LibAsset.ERC1155_ASSET_CLASS || matchNft.assetClass == LibAsset.ERC721_ASSET_CLASS) {
            (address token, uint tokenId) = abi.decode(matchNft.data, (address, uint));
            return royaltiesRegistry.getRoyalties(token, tokenId);
        } else if (matchNft.assetClass == LibERC1155LazyMint.ERC1155_LAZY_ASSET_CLASS) {
            (, LibERC1155LazyMint.Mint1155Data memory data) = abi.decode(matchNft.data, (address, LibERC1155LazyMint.Mint1155Data));
            return data.royalties;
        } else if (matchNft.assetClass == LibERC721LazyMint.ERC721_LAZY_ASSET_CLASS) {
            (, LibERC721LazyMint.Mint721Data memory data) = abi.decode(matchNft.data, (address, LibERC721LazyMint.Mint721Data));
            return data.royalties;
        }
        LibPart.Part[] memory empty;
        return empty;
    }

    function transferFees(
        LibAsset.AssetType memory matchCalculate,
        uint rest,
        uint amount,
        LibPart.Part[] memory fees,
        address from,
        bytes4 transferDirection,
        bytes4 transferType
    ) internal returns (uint restValue, uint totalFees) {
        totalFees = 0;
        restValue = rest;
        for (uint256 i = 0; i < fees.length; i++) {
            totalFees = totalFees.add(fees[i].value);
            (uint newRestValue, uint feeValue) = subFeeInBp(restValue, amount, fees[i].value);
            restValue = newRestValue;
            if (feeValue > 0) {
                transfer(LibAsset.Asset(matchCalculate, feeValue), from, fees[i].account, transferDirection, transferType);
            }
        }
    }

    function transferPayouts(
        LibAsset.AssetType memory matchCalculate,
        uint amount,
        address from,
        LibPart.Part[] memory payouts,
        bytes4 transferDirection
    ) internal {
        require(payouts.length > 0, "transferPayouts: nothing to transfer");
        uint sumBps = 0;
        uint restValue = amount;
        for (uint256 i = 0; i < payouts.length - 1; i++) {
            uint currentAmount = amount.bp(payouts[i].value);
            sumBps = sumBps.add(payouts[i].value);
            if (currentAmount > 0) {
                restValue = restValue.sub(currentAmount);
                transfer(LibAsset.Asset(matchCalculate, currentAmount), from, payouts[i].account, transferDirection, PAYOUT);
            }
        }
        LibPart.Part memory lastPayout = payouts[payouts.length - 1];
        sumBps = sumBps.add(lastPayout.value);
        require(sumBps == 10000, "Sum payouts Bps not equal 100%");
        if (restValue > 0) {
            transfer(LibAsset.Asset(matchCalculate, restValue), from, lastPayout.account, transferDirection, PAYOUT);
        }
    }

    function calculateTotalAmount(
        uint amount,
        uint feeOnTopBp,
        LibPart.Part[] memory orderOriginFees
    ) override public pure returns (uint total) {
        total = amount.add(amount.bp(feeOnTopBp));
        for (uint256 i = 0; i < orderOriginFees.length; i++) {
            total = total.add(amount.bp(orderOriginFees[i].value));
        }
    }

    function subFeeInBp(uint value, uint total, uint feeInBp) internal pure returns (uint newValue, uint realFee) {
        return subFee(value, total.bp(feeInBp));
    }

    function subFee(uint value, uint fee) internal pure returns (uint newValue, uint realFee) {
        if (value > fee) {
            newValue = value.sub(fee);
            realFee = fee;
        } else {
            newValue = 0;
            realFee = value;
        }
    }

    receive() external payable {}

    uint256[46] private __gap;
}
