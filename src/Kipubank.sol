// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// OpenZeppelin
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Chainlink
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title KipuBank
 * @notice Contrato bancario con soporte multi-token, límites en USD y contabilidad interna.
 * @dev Los saldos se mantienen en unidades nativas del token. Usa Chainlink para valoraciones en USD.
 */
contract KipuBank is Ownable {
    using SafeERC20 for IERC20;

    // --- CONSTANTES Y VARIABLES INMUTABLES ---
    uint256 public immutable WITHDRAWAL_LIMIT_USD; // Límite de retiro por transacción en USD
    uint256 public immutable BANK_CAP_USD; // Límite global del banco en USD
    AggregatorV3Interface public immutable ETH_USD_PRICE_FEED; // Price Feed de ETH/USD

    // --- ALMACENAMIENTO ---
    mapping(address => mapping(address => uint256)) private s_balances; // user => token => balance
    uint256 public totalDepositedUSD; // Total depositado en USD
    mapping(address => AggregatorV3Interface) public tokenPriceFeeds; // Token => Price Feed
    mapping(address => uint8) public tokenDecimals; // Token => Decimales
    mapping(address => bool) public supportedTokens; // Lista blanca de tokens
    bool private _locked; // Reentrancy guard

    // --- ERRORES ---
    error CapExceeded(uint256 available, uint256 attempted);
    error InsufficientBalance(uint256 requested, uint256 available);
    error WithdrawalLimitExceeded(uint256 requestedUSD, uint256 limitUSD);
    error ZeroAmount();
    error ReentrancyGuard();
    error TransferFailed(address token, address to, uint256 amount);
    error ChainlinkCallFailed();
    error DecimalsNotSet(address token);
    error UnsupportedToken(address token);

    // --- EVENTOS ---
    event Deposit(address indexed user, address indexed token, uint256 amount, uint256 newBalance);
    event Withdrawal(address indexed user, address indexed token, uint256 amount, uint256 newBalance);
    event TokenAdded(address indexed token, address indexed feedAddress, uint8 decimals);

    // --- MODIFICADORES ---
    modifier nonReentrant() {
        if (_locked) revert ReentrancyGuard();
        _locked = true;
        _;
        _locked = false;
    }

    // --- CONSTRUCTOR ---
    /**
     * @notice Inicializa el contrato con límites en USD y Price Feed de ETH.
     * @param bankCapUSD Límite global del banco en USD.
     * @param withdrawalLimitUSD Límite de retiro por transacción en USD.
     * @param ethPriceFeed Dirección del Price Feed de ETH/USD.
     */
    constructor(uint256 bankCapUSD, uint256 withdrawalLimitUSD, address ethPriceFeed) Ownable(msg.sender) {
        BANK_CAP_USD = bankCapUSD;
        WITHDRAWAL_LIMIT_USD = withdrawalLimitUSD;
        ETH_USD_PRICE_FEED = AggregatorV3Interface(ethPriceFeed);
        supportedTokens[address(0)] = true; // ETH siempre soportado
        tokenDecimals[address(0)] = 18; // Decimales de ETH
    }

    // --- FUNCIONES ADMINISTRATIVAS ---
    /**
     * @notice Agrega soporte para un nuevo token ERC-20.
     * @param token Dirección del token.
     * @param feedAddress Dirección del Price Feed de Chainlink.
     * @param decimals Número de decimales del token.
     */
    function addSupportedToken(address token, address feedAddress, uint8 decimals) external onlyOwner {
        if (decimals == 0) revert DecimalsNotSet(token);
        supportedTokens[token] = true;
        tokenPriceFeeds[token] = AggregatorV3Interface(feedAddress);
        tokenDecimals[token] = decimals;
        emit TokenAdded(token, feedAddress, decimals);
    }

    // --- FUNCIONES DE DEPÓSITO ---
    /**
     * @notice Recibe ETH y registra el depósito.
     */
    receive() external payable {
        _deposit(address(0), msg.value);
    }

    /**
     * @notice Deposita ETH.
     */
    function depositETH() external payable nonReentrant {
        _deposit(address(0), msg.value);
    }

    /**
     * @notice Deposita tokens ERC-20.
     * @param token Dirección del token.
     * @param amount Cantidad a depositar.
     */
    function depositERC20(address token, uint256 amount) external nonReentrant {
        _deposit(token, amount);
    }

    /**
     * @dev Lógica interna para depósitos.
     * @param token Dirección del token (address(0) para ETH).
     * @param amount Cantidad en unidades nativas.
     */
    function _deposit(address token, uint256 amount) private {
        if (amount == 0) revert ZeroAmount();
        if (!supportedTokens[token]) revert UnsupportedToken(token);

        // Calcular valor en USD
        uint256 depositUSD = _getTokenValueInUSD(token, amount);
        uint256 newTotalUSD = totalDepositedUSD + depositUSD;
        if (newTotalUSD > BANK_CAP_USD) revert CapExceeded(BANK_CAP_USD - totalDepositedUSD, depositUSD);

        // Transferir tokens (si no es ETH)
        if (token != address(0)) {
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        }

        // Actualizar estado
        s_balances[msg.sender][token] += amount;
        totalDepositedUSD = newTotalUSD;

        emit Deposit(msg.sender, token, amount, s_balances[msg.sender][token]);
    }

    // --- FUNCIONES DE RETIRO ---
    /**
     * @notice Retira ETH o tokens ERC-20.
     * @param token Dirección del token (address(0) para ETH).
     * @param amount Cantidad a retirar.
     */
    function withdraw(address token, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (!supportedTokens[token]) revert UnsupportedToken(token);

        uint256 balance = s_balances[msg.sender][token];
        if (amount > balance) revert InsufficientBalance(amount, balance);

        uint256 amountUSD = _getTokenValueInUSD(token, amount);
        if (amountUSD > WITHDRAWAL_LIMIT_USD) revert WithdrawalLimitExceeded(amountUSD, WITHDRAWAL_LIMIT_USD);

        // Actualizar estado
        s_balances[msg.sender][token] = balance - amount;
        totalDepositedUSD -= amountUSD;

        // Transferir
        if (token == address(0)) {
            (bool success, ) = payable(msg.sender).call{value: amount}("");
            if (!success) revert TransferFailed(token, msg.sender, amount);
        } else {
            IERC20(token).safeTransfer(msg.sender, amount);
        }

        emit Withdrawal(msg.sender, token, amount, s_balances[msg.sender][token]);
    }

    // --- FUNCIONES DE ORÁCULO ---
    /**
     * @notice Calcula el valor en USD de una cantidad de tokens.
     * @param token Dirección del token (address(0) para ETH).
     * @param amount Cantidad en unidades nativas.
     * @return Valor en USD con 8 decimales.
     */
    function _getTokenValueInUSD(address token, uint256 amount) private view returns (uint256) {
        AggregatorV3Interface priceFeed = token == address(0) ? ETH_USD_PRICE_FEED : tokenPriceFeeds[token];
        uint8 decimals = token == address(0) ? 18 : tokenDecimals[token];

        if (decimals == 0) revert DecimalsNotSet(token);

        (, int256 price, , uint256 updatedAt, ) = priceFeed.latestRoundData();
        if (price <= 0 || updatedAt == 0 || block.timestamp - updatedAt > 3600) revert ChainlinkCallFailed();

        uint256 numerator = amount * uint256(price);
        return decimals > 8
            ? numerator / (10 ** (decimals - 8)) / 10**8
            : numerator * (10 ** (8 - decimals)) / 10**8;
    }

    // --- FUNCIONES DE VISTA ---
    /**
     * @notice Consulta el saldo de un usuario para un token.
     * @param user Dirección del usuario.
     * @param token Dirección del token (address(0) para ETH).
     * @return Saldo en unidades nativas.
     */
    function getBalance(address user, address token) external view returns (uint256) {
        return s_balances[user][token];
    }

    /**
     * @notice Consulta el precio más reciente de un token.
     * @param token Dirección del token (address(0) para ETH).
     * @return Precio en USD con 8 decimales.
     */
    function getLatestPrice(address token) external view returns (int256) {
        AggregatorV3Interface priceFeed = token == address(0) ? ETH_USD_PRICE_FEED : tokenPriceFeeds[token];
        (, int256 price, , uint256 updatedAt, ) = priceFeed.latestRoundData();
        if (price <= 0 || updatedAt == 0 || block.timestamp - updatedAt > 3600) revert ChainlinkCallFailed();
        return price;
    }
}
