// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.4;


interface DentacoinToken {
    function approve(address spender, uint256 amount) external returns (bool);

    function transfer(address recipient, uint256 amount) external returns (bool);

    function balanceOf(address account) external view returns (uint256);
}


interface ISwapRouter {
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
}


interface IQuoter {
    function quoteExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    ) external returns (uint256 amountOut);
}


interface StakingProgram {
    function whitelistedStake(uint256 _tokens_amount, address _staker) external;
}


contract Ownable {
    address public owner;

    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender == owner)
            _;
    }

    function transferOwnership(address newOwner) public onlyOwner {
        if (newOwner != address(0)) owner = newOwner;
    }
}


contract SafeMath {
    /**
    * @dev Multiplies two numbers, reverts on overflow.
    */
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        // Gas optimization: this is cheaper than requiring 'a' not being zero, but the
        // benefit is lost if 'b' is also tested.
        // See: https://github.com/OpenZeppelin/openzeppelin-solidity/pull/522
        if (a == 0) {
            return 0;
        }

        uint256 c = a * b;
        require(c / a == b);

        return c;
    }

    /**
    * @dev Integer division of two numbers truncating the quotient, reverts on division by zero.
    */
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b > 0);
        // Solidity only automatically asserts when dividing by 0
        uint256 c = a / b;
        // assert(a == b * c + a % b); // There is no case in which this doesn't hold

        return c;
    }

    /**
    * @dev Subtracts two numbers, reverts on overflow (i.e. if subtrahend is greater than minuend).
    */
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b <= a);
        uint256 c = a - b;

        return c;
    }

    /**
    * @dev Adds two numbers, reverts on overflow.
    */
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a);

        return c;
    }

    /**
    * @dev Divides two numbers and returns the remainder (unsigned integer modulo),
    * reverts when dividing by zero.
    */
    function mod(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b != 0);
        return a % b;
    }
}


contract StakingAccelerator is Ownable, SafeMath {
    uint256 public incentivePercentage = 5;

    // DentacoinToken Instance
    address public tokenAddress;
    DentacoinToken tokenContract;

    // SwapRouter Instance
    ISwapRouter swapRouter;

    // StakingProgram Instance
    StakingProgram stakingContract;

    // Quoter instance
    IQuoter quoter;

    bool public contractStopped = false;
    uint16 public slippage = 20;
    uint24 public uniswapFee = 3000;
    address public tokenIn;

    constructor(
        address _tokenAddress,
        address _tokenIn,
        address _swapRouterAddress,
        address _stakingAddress,
        address _quoterAddress
    ) payable {
        tokenAddress = _tokenAddress;
        tokenIn = _tokenIn;
        tokenContract = DentacoinToken(_tokenAddress);
        swapRouter = ISwapRouter(_swapRouterAddress);
        stakingContract = StakingProgram(_stakingAddress);
        quoter = IQuoter(_quoterAddress);

        tokenContract.approve(_stakingAddress, 115792089237316195423570985008687907853269984665640564039457584007913129639935);
    }

    // ==================================== EVENTS ====================================
    event BoughtAndStaked(address indexed _staker, uint256 _tokenIn, uint256 _tokenOut);
    // ==================================== /EVENTS ====================================

    // ==================================== MODIFIERS ====================================
    modifier checkIfContractStopped() {
        require(!contractStopped, "ERROR: contract is stopped.");
        _;
    }
    // ==================================== /MODIFIERS ====================================

    // ==================================== CONTRACT ADMIN ====================================
    function stopUnstopStaking() external onlyOwner {
        if (!contractStopped) {
            contractStopped = true;
        } else {
            contractStopped = false;
        }
    }

    function setContractParams(
        uint24 _uniswapFee,
        uint16 _slippage,
        uint256 _incentivePercentage
    ) external onlyOwner {
        require(_slippage < 100, "ERROR: INVALID_SLIPPAGE");

        uniswapFee = _uniswapFee;
        slippage = _slippage;
        incentivePercentage = _incentivePercentage;
    }
    // ==================================== /CONTRACT ADMIN ====================================

    // ===================================== CONTRACT BODY =====================================
    function buyAndStake() external payable checkIfContractStopped {
        require(msg.value > 0, "ERROR: NOT_ENOUGH_ETH");

        if (incentivePercentage > 0) {
            require(tokenContract.balanceOf(address(this)) > 0, "ERROR: NOT_ENOUGH_TOKEN_BALANCE");
        }

        // calculate Uniswap amountOutMinimum to prevent sandwich attack
        uint256 quoteAmountOut = quoter.quoteExactInputSingle(tokenIn, tokenAddress, uniswapFee, msg.value, 0);
        require(quoteAmountOut > 0, "ERROR: FAILED_quoteAmountOut");
        uint256 amountOutMinimum = div(mul(quoteAmountOut, sub(100, slippage)), 100);

        // Uniswap purchase
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({tokenIn: tokenIn, tokenOut: tokenAddress, fee: uniswapFee, recipient: address(this), amountIn: msg.value, amountOutMinimum: amountOutMinimum, sqrtPriceLimitX96: 0});
        uint256 amountOut = swapRouter.exactInputSingle{value: msg.value}(params);

        // Add incentive to the buyers amount
        uint256 incentiveAmount = div(mul(amountOut, incentivePercentage), 100);
        amountOut = add(amountOut, incentiveAmount);

        // Stake the amount as from the name of the buyer
        stakingContract.whitelistedStake(amountOut, msg.sender);

        emit BoughtAndStaked(msg.sender, msg.value, amountOut);
    }

    function withdrawTokens() external onlyOwner {
        tokenContract.transfer(owner, tokenContract.balanceOf(address(this)));
    }
    // ===================================== /CONTRACT BODY =====================================
}

// MN bby ¯\_(ツ)_/¯