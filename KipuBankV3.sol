// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @title Contrato KipuBank (V3, TP4)
 * @author Agustín Cerdá
 */

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol"; // Para aprobaciones y transferencias
import "https://github.com/Uniswap/permit2/blob/main/src/interfaces/IPermit2.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";


/*//////////////////////////////////////////////////////////////
                    Interfaz Uniswap V2 Router
//////////////////////////////////////////////////////////////*/


contract KipuBank is AccessControl, Pausable, ReentrancyGuard { 

    using SafeERC20 for IERC20;
    /** VARIABLES */
 
    // mapping multi-token: usuario -> token -> balance
    mapping(address user => mapping(address token => uint256 amount)) private s_balances;
    // address(0) representa ETH
    // amount -> cuanto tiene depositado el usuario en ese token

    uint256 public immutable MIN_RETIRO = 0.001 ether;
    uint256 public immutable MAX_RETIRO = 10 ether;

    uint256 public bankCapUSD; // Límite total del banco en USDC
    uint256 public totalDeposits;
    uint256 public totalWithdrawals;
    uint256 public totalBankUSD; // total en USDC del banco, se actualiza dinámicamente

    /// @dev identificador del rol de pauser
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE"); // hash único para representar el rol

    /// @notice mapping token => Chainlink price feed
    mapping(address token => AggregatorV3Interface) public priceFeeds;

    /// @notice Instancia de UniswapV2 router y USDC address
    IUniswapV2Router02 public immutable uniswapRouter;
    IPermit2 public immutable i_permit2;
    address public immutable USDC;

    uint256 private constant SWAP_DEADLINE_OFFSET = 300; // 5 minutos

    /*//////////////////////////////////////////////////////////////
                                Eventos
    //////////////////////////////////////////////////////////////*/

    event Deposit(address indexed user, address indexed token, uint256 amount);
    event Withdraw(address indexed user, address indexed token, uint256 amount);
    event BankCapUpdated(uint256 oldCapUSD, uint256 newCapUSD);
    event SwappedToUSDC(address indexed user, address indexed tokenIn, uint256 amountIn, uint256 amountUSDC);

    /*//////////////////////////////////////////////////////////////
                                Errores
    //////////////////////////////////////////////////////////////*/

    error InsufficientBalance(uint256 requested, uint256 available);
    error TransferFailed(bytes errorData);
    error AmountTooSmall(uint256 requested, uint256 minAllowed);
    error AmountTooLarge(uint256 requested, uint256 maxAllowed);
    error DepositLimitReached(uint256 requestedTotalUSD, uint256 bankCapUSD);
    error ContractPaused();
    error NoPriceFeed(address token);
    error OracleCompromised();
    error StalePrice();
    error ZeroAmount();
    error SwapFailed();


    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @param _bankCapUSD límite del banco en unidades mínimas de USDC (ej: para $1 = 1*10^6 si USDC=6dec)
     * @param _uniswapRouter dirección del Uniswap V2 Router
     * @param _usdc dirección del token USDC
     */
    constructor(uint256 _bankCapUSD, address _uniswapRouter, address _usdc, address _permit2) {
        bankCapUSD = _bankCapUSD;
        uniswapRouter = IUniswapV2Router02(_uniswapRouter);
        USDC = _usdc;
        i_permit2 = IPermit2(_permit2);


        // delegación de roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);    
    }
    /*//////////////////////////////////////////////////////////////
                                Funciones de precio USD
    //////////////////////////////////////////////////////////////*/

    /// @notice Asignar un price feed Chainlink a un token
    function setPriceFeed(address token, address feed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        priceFeeds[token] = AggregatorV3Interface(feed);
    }

    /// @notice Obtiene el precio en USD del token (una unidad del token)
    function getTokenPriceUSD(address token) public view returns (uint256 price, uint8 decimals) {
        AggregatorV3Interface feed = priceFeeds[token];
        if(address(feed) == address(0)) revert NoPriceFeed(token);

        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if(answer <= 0) revert OracleCompromised();
        if(block.timestamp - updatedAt > 3600) revert StalePrice();

        price = uint256(answer);
        decimals = feed.decimals();
    }

    /// @notice Convierte cantidad de token a USD usando Chainlink
    function getValueInUSD(address token, uint256 amount) public view returns (uint256) {
        (uint256 price, uint8 decimals) = getTokenPriceUSD(token);
        return (amount * price) / (10 ** decimals);
    }

    /// @notice Obtiene el valor total en USD de todos los depósitos en el banco 
    function getTotalBankValueUSD() public view returns (uint256 totalValueUSD) {
        return totalBankUSD;
    }

    /*//////////////////////////////////////////////////////////////
                                Depósitos Nativos (ETH)
    //////////////////////////////////////////////////////////////*/

    receive() external payable {
        depositETH(1); // Por la cantidad minima aceptada
    }

    fallback() external payable {
        depositETH(1);
    }

    /**
     * @notice deposita ETH: convierte ETH a USDC con Uniswap V2 y acredita USDC en el balance del usuario
     * @param minAmountOut cantidad mínima de USDC aceptada para el swap
     * @dev respeta bankCapUSD (en USDC) usando la estimación getAmountsOut antes del swap
     */
    function depositETH(uint256 minAmountOut) public payable whenNotPaused nonReentrant {
        uint256 ethAmount = msg.value;
        if (ethAmount == 0) revert ZeroAmount();

        address[] memory path = new address[](2);
        path[0] = uniswapRouter.WETH();
        path[1] = USDC;
        uint[] memory amountsOut = uniswapRouter.getAmountsOut(ethAmount, path);
        uint256 estimatedUSDC = amountsOut[amountsOut.length - 1];

        if (totalBankUSD + estimatedUSDC > bankCapUSD) revert DepositLimitReached(totalBankUSD + estimatedUSDC, bankCapUSD);

        uint256 deadline = block.timestamp + SWAP_DEADLINE_OFFSET;
        uint[] memory amounts = uniswapRouter.swapExactETHForTokens{value: ethAmount}(minAmountOut, path, address(this), deadline);

        uint256 usdcReceived = amounts[amounts.length - 1];
    if (usdcReceived == 0) revert SwapFailed();

    _deposit(msg.sender, USDC, usdcReceived);

    emit SwappedToUSDC(msg.sender, address(0), ethAmount, usdcReceived);
}


    /*//////////////////////////////////////////////////////////////
                                Depósitos ERC20
    //////////////////////////////////////////////////////////////*/

/**
 * @notice Permite depositar un token ERC20 en el banco.
 * @dev Si el token no es USDC, se intercambia automáticamente a USDC mediante Uniswap V2.
 * @param token Dirección del token ERC20 que se desea depositar.
 * @param amount Cantidad de tokens a depositar.
 * @param deadline Tiempo máximo para completar el swap (en segundos desde epoch).
 */
function depositToken(address token, uint256 amount, uint256 deadline) external whenNotPaused {
    if (amount == 0) revert ZeroAmount();

    // Transferir los tokens desde el usuario al contrato
    IERC20(token).transferFrom(msg.sender, address(this), amount);

    uint256 usdcReceived;

    if (token != USDC) {
        // Aprobar al router para hacer swap
        IERC20(token).approve(address(uniswapRouter), 0);
        IERC20(token).approve(address(uniswapRouter), amount);

        // Ruta del swap: token -> USDC
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = USDC;

        // Ejecutar swap en Uniswap V2
        uint256[] memory amounts = uniswapRouter.swapExactTokensForTokens(
            amount,
            0,
            path,
            address(this),
            deadline
        );

        usdcReceived = amounts[amounts.length - 1];
    } else {
        usdcReceived = amount;
    }

    // Verificar límite del banco
    uint256 newTotal = totalBankUSD + usdcReceived;
    if (newTotal > bankCapUSD) revert DepositLimitReached(newTotal, bankCapUSD);

    // Acreditar al usuario
    s_balances[msg.sender][USDC] += usdcReceived;
    totalBankUSD = newTotal;
    totalDeposits += 1;

    emit Deposit(msg.sender, USDC, usdcReceived);
}



    /*//////////////////////////////////////////////////////////////
                                Retiros Nativos (ETH)
    //////////////////////////////////////////////////////////////*/

    function withdrawETH(uint256 amount) external whenNotPaused {
        if (amount < MIN_RETIRO) revert AmountTooSmall(amount, MIN_RETIRO);
        if (amount > MAX_RETIRO) revert AmountTooLarge(amount, MAX_RETIRO);

        uint256 balance = s_balances[msg.sender][address(0)];
        if (balance < amount) revert InsufficientBalance(amount, balance);

        _withdraw(msg.sender, address(0), amount);

        (bool success, bytes memory err) = payable(msg.sender).call{value: amount}("");
        if (!success) revert TransferFailed(err);
    }

    /*//////////////////////////////////////////////////////////////
                                Retiros ERC20
    //////////////////////////////////////////////////////////////*/

    function withdrawToken(address token, uint256 amount) external whenNotPaused {
        uint256 balance = s_balances[msg.sender][token];
        if (balance < amount) revert InsufficientBalance(amount, balance);

        _withdraw(msg.sender, token, amount);

        bool success = IERC20(token).transfer(msg.sender, amount);
        if(!success) revert TransferFailed("");
    }

    /*//////////////////////////////////////////////////////////////
                        Funciones privadas de contabilidad interna
    //////////////////////////////////////////////////////////////*/

    function _deposit(address user, address token, uint256 amount) private {
        s_balances[user][token] += amount;

        // actualizar totalBankUSD (en USDC)
        uint256 valueUSD;
        if(token == USDC) {
            valueUSD = amount;
        } else {
            // Convierte a USDC el token depositado
            if(address(priceFeeds[token]) != address(0)) { // si existe oraculo en priceFeeds, presencia del token
                valueUSD = getValueInUSD(token, amount);
            } else {
                valueUSD = 0;
            }
        }

        totalBankUSD += valueUSD;

        totalDeposits += 1;
        emit Deposit(user, token, amount);
    }

    function _withdraw(address user, address token, uint256 amount) private {
        s_balances[user][token] -= amount;

        // actualizar totalBankUSD (en USDC)
        uint256 valueUSD;
        if(token == USDC) {
            valueUSD = amount;
        } else {
            if(address(priceFeeds[token]) != address(0)) {
                valueUSD = getValueInUSD(token, amount);
            } else {
                valueUSD = 0;
            }
        }

        if(valueUSD > totalBankUSD) {
            totalBankUSD = 0;
        } else {
            totalBankUSD -= valueUSD;
        }

        totalWithdrawals += 1;
        emit Withdraw(user, token, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                Funciones de control
    //////////////////////////////////////////////////////////////*/

    function pauseBank() external onlyRole(PAUSER_ROLE) {
        _pause(); 
    }

    function unpauseBank() external onlyRole(PAUSER_ROLE) {
        _unpause(); 
    }

    function setBankCapUSD(uint256 newCapUSD) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldCap = bankCapUSD;
        bankCapUSD = newCapUSD;
        emit BankCapUpdated(oldCap, newCapUSD);
    }   

    /*//////////////////////////////////////////////////////////////
                                View
    //////////////////////////////////////////////////////////////*/

    function getBalance(address user, address token) external view returns (uint256) {
        return s_balances[user][token];
    }
}
