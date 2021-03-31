// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;

import "./IPool.sol";
import "./../protocols/compound/PriceFeed.sol";
import "./../protocols/compound/Comptroller.sol";
import "./../protocols/compound/CErc20.sol";
import "./../ERC20/Erc20.sol";

contract DAICompoundLeveragePool is IPool {
    Comptroller private _comptroller;
    CErc20 private _cDai;
    Erc20 private _dai;
    PriceFeed private _oracle;

    event Log(string, uint256);

    constructor(
        address _comptrollerAddress,
        address _cDaiAddress,
        address _daiAddress,
        address _oracleAddress
    ) public {
        _comptroller = Comptroller(_comptrollerAddress);
        _cDai = CErc20(_cDaiAddress);
        _dai = Erc20(_daiAddress);
        _oracle = PriceFeed(_oracleAddress);

        // Enter cDAI market
        _enterMarkets();
    }

    /// @dev Enter the market to borrow another type of asset
    function _enterMarkets() private {
        address[] memory cTokens = new address[](1);
        cTokens[0] = address(_cDai);
        uint256[] memory errors = _comptroller.enterMarkets(cTokens);

        if (errors[0] != 0) {
            revert("Comptroller.enterMarkets Error");
        }
    }

    function getName() external pure override returns (string memory) {
        return "DAI Compound Leverage Pool";
    }

    function deposit(uint256 _amount) external override {
        // Deposit token on user behalf
        _dai.transferFrom(msg.sender, address(this), _amount);

        // Approve transfer
        _dai.approve(address(_cDai), _amount);

        // Supply underlying as collateral
        uint256 mintError = _cDai.mint(_amount);
        require(mintError == 0, "CErc20.mint Error");

        // Get account's total liquidity
        (uint256 liquidityError, uint256 liquidity, uint256 shortfall) =
            _comptroller.getAccountLiquidity(address(this));
        if (liquidityError != 0) {
            revert("Comptroller.getAccountLiquidity Error");
        }
        require(shortfall == 0, "account underwater");
        require(liquidity > 0, "account has excess collateral");
        emit Log("Account liquidity", liquidity);

        // Borrow maximum of underlying
        uint256 cDaiPrice = _oracle.getUnderlyingPrice(address(_cDai));
        uint256 maxBorrowUnderlying = liquidity / cDaiPrice;
        _cDai.borrow(maxBorrowUnderlying * 10**18);

        // Get borrowed amount
        uint256 borrowed = _cDai.borrowBalanceCurrent(address(this));
        emit Log("DAI borrowed successfully", borrowed);
    }

    /// @dev Repay the borrow and convert back
    function _closePosition(uint256 _amount) private {
        // Approve transfer
        _dai.approve(address(_cDai), _amount);

        // Repay borrow and get COMP reward
        uint256 error = _cDai.repayBorrow(_amount);
        require(error == 0, "CErc20.repayBorrow Error");

        // Redeem cDai for Dai
        uint256 balancecDai = _cDai.balanceOf(address(this));
        _cDai.redeem(balancecDai);
    }

    function withdraw(uint256 _amount) external override {}

    function withdrawAll() external override {
        uint256 borrow = _cDai.borrowBalanceCurrent(address(this));

        // Transfer more DAI to repay if necessary
        uint256 availableForRepay = _dai.balanceOf(address(this));
        int256 shortage = int256(borrow) - int256(availableForRepay);
        if (shortage > 0) {
            _dai.transferFrom(msg.sender, address(this), uint256(shortage));
            emit Log("Transfering to repay", uint256(shortage));
        }

        // Close leverage position
        _closePosition(borrow);

        // Transfer DAI back to user
        uint256 balance = _dai.balanceOf(address(this));
        _dai.transfer(msg.sender, balance);
    }
}