// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// OpenZeppelin
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Chainlink
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title KipuBank
 * @dev Contrato bancario con soporte multi-token, límites en USD y contabilidad interna.
 * La contabilidad de saldos internos (s_balances) se mantiene en unidades nativas del token.
 */
contract KipuBank is Ownable {
    
    // --- CONSTANTES Y VARIABLES INMUTABLES ---
    
    /// @dev Límite de retiro por transacción, en USD (ej. 100 USD).
    uint256 public immutable WITHDRAWAL_LIMIT_USD; 
    
    /// @dev Límite global total del banco, en USD.
    uint256 public immutable BANK_CAP_USD; 
    
    /// @dev La dirección del Price Feed de Chainlink para ETH/USD. INMUTABLE.
    AggregatorV3Interface public immutable ETH_USD_PRICE_FEED;

    // --- ALMACENAMIENTO MULTI-TOKEN Y VALORES DE CONTROL ---
    
    // Mapeo anidado: user => tokenAddress => balance (en unidades nativas del token)
    mapping(address => mapping(address => uint256)) private s_balances;
    
    // Total de valor depositado en USD (para aplicar el BANK_CAP_USD). 
    // NOTA: Debe ser actualizado con cada depósito/retiro de CUALQUIER token.
    uint256 public totalDepositedUSD;
    
    // Mapeo para rastrear la dirección del Price Feed de Chainlink para cada token ERC-20.
    mapping(address => AggregatorV3Interface) public tokenPriceFeeds;
    
    // Mapeo para almacenar los decimales de cada token ERC-20 (para la conversión).
    mapping(address => uint8) public tokenDecimals;
    
    // --- REENTRANCY GUARD ---
    uint256 private _status;

    // --- ERRORES PERSONALIZADOS (Añadidos para Debugging) ---
    error CapExceeded(uint256 availableSpaceUSD, uint256 depositAttemptUSD);
    error InsufficientBalance(uint256 requested, uint256 available, address token);
    error WithdrawalLimitExceeded(uint256 requestedUSD, uint256 limitUSD);
    error ZeroAmount(address token);
    error ReentrancyGuard();
    error TransferFromFailed(address token, address from, uint256 amount);
    error ExternalTransferFailed(address token, address recipient, uint256 amount);
    error ChainlinkCallFailed();
    error DecimalsNotSet(address token);

    // --- EVENTOS ---
    event DepositSuccessful(address indexed user, address indexed token, uint256 amount, uint256 newBalance);
    event WithdrawalSuccessful(address indexed user, address indexed token, uint256 amount, uint256 newBalance);
    event EtherReceived(address indexed sender, uint256 amount);
    event PriceFeedSet(address indexed token, address indexed feedAddress);

    // --- MODIFICADORES ---
    modifier nonReentrant() {
        if (_status != 0) {
            revert ReentrancyGuard();
        }
        _status = 1;
        _;
        _status = 0;
    }

    // --- CONSTRUCTOR ---
    /**
     * @dev Inicializa el contrato con límites en USD y la dirección del Price Feed de ETH.
     */
    constructor(
        uint256 _bankCapUSD, 
        uint256 _withdrawalLimitUSD,
        address _ethPriceFeed
    ) Ownable(msg.sender) {
        BANK_CAP_USD = _bankCapUSD;
        WITHDRAWAL_LIMIT_USD = _withdrawalLimitUSD;
        ETH_USD_PRICE_FEED = AggregatorV3Interface(_ethPriceFeed);
    }
    
    // -------------------------------------------------------------------------
    //                              FUNCIONES ADMINISTRATIVAS
    // -------------------------------------------------------------------------
    
    /**
     * @notice Permite al dueño establecer el Price Feed para un nuevo token ERC-20.
     * @dev Se requiere que los decimales del token ya estén establecidos.
     */
    function setTokenPriceFeed(address _token, address _feedAddress) external onlyOwner {
        if (tokenDecimals[_token] == 0) {
            // Nota: Este check asume que los decimales del token se establecen primero.
            revert DecimalsNotSet(_token);
        }
        tokenPriceFeeds[_token] = AggregatorV3Interface(_feedAddress);
        emit PriceFeedSet(_token, _feedAddress);
    }
    
    /**
     * @notice Permite al dueño establecer los decimales de un nuevo token ERC-20.
     * @dev Los decimales son necesarios para la correcta valoración.
     */
    function setTokenDecimals(address _token, uint8 _decimals) external onlyOwner {
        tokenDecimals[_token] = _decimals;
    }
    
    // -------------------------------------------------------------------------
    //                              FUNCIONES DE DEPÓSITO
    // -------------------------------------------------------------------------

    receive() external payable {
        _handleDeposit(address(0), msg.value);
        emit EtherReceived(msg.sender, msg.value);
    }

    function depositETH() external payable {
        _handleDeposit(address(0), msg.value);
    }

    /**
     * @notice Permite a un usuario depositar tokens ERC-20.
     */
    function depositERC20(address _token, uint256 _amount) external {
        _handleDeposit(_token, _amount);
    }
    
    // -------------------------------------------------------------------------
    //                              FUNCIONES DE RETIRO
    // -------------------------------------------------------------------------

    /**
     * @notice Permite retirar ETH o tokens ERC-20.
     * @dev Sigue el patrón Checks-Effects-Interactions (CEI) y usa nonReentrant.
     */
    function withdraw(address _token, uint256 _amount) external nonReentrant {
        // --- Checks ---
        if (_amount == 0) revert ZeroAmount(_token);
        
        uint256 userBalance = s_balances[msg.sender][_token];
        if (_amount > userBalance) {
             revert InsufficientBalance({
                 requested: _amount,
                 available: userBalance,
                 token: _token
             });
        }
        
        // 1. Obtener la valoración en USD y aplicar límites
        uint256 amountUSD = _getTokenValueInUSD(_token, _amount);
        if (amountUSD > WITHDRAWAL_LIMIT_USD) {
            revert WithdrawalLimitExceeded({
                requestedUSD: amountUSD, 
                limitUSD: WITHDRAWAL_LIMIT_USD
            });
        }

        // --- Effects ---
        // 1. Reduce el balance interno del usuario
        s_balances[msg.sender][_token] = userBalance - _amount;
        
        // 2. Reduce el valor total depositado en USD
        // Utilizamos la misma valoración USD obtenida previamente para mantener la consistencia
        totalDepositedUSD -= amountUSD; 

        // --- Interactions / Events ---
        if (_token == address(0)) {
            _safeTransferEther(msg.sender, _amount);
        } else {
            _safeTransferERC20(_token, msg.sender, _amount);
        }
        
        emit WithdrawalSuccessful(msg.sender, _token, _amount, s_balances[msg.sender][_token]);
    }

    // -------------------------------------------------------------------------
    //                             LÓGICA PRIVADA CENTRAL
    // -------------------------------------------------------------------------

    /**
     * @dev Lógica central para depósitos (ETH o ERC-20). Aplica el BANK_CAP.
     * @param _token La dirección del token (address(0) para ETH).
     * @param _amount La cantidad de Ether/tokens recibida (en unidades nativas).
     */
    function _handleDeposit(address _token, uint256 _amount) private {
        // --- Checks ---
        if (_amount == 0) revert ZeroAmount(_token);
        
        // 1. Obtener la valoración en USD del depósito y aplicar el límite global (BANK_CAP)
        uint256 depositUSD = _getTokenValueInUSD(_token, _amount);
        if (totalDepositedUSD + depositUSD > BANK_CAP_USD) {
            revert CapExceeded({
                availableSpaceUSD: BANK_CAP_USD - totalDepositedUSD,
                depositAttemptUSD: depositUSD
            });
        }
        
        // --- Effects ---
        // 1. Si es ERC-20, transferir los tokens ANTES de actualizar el estado (CEI)
        if (_token != address(0)) {
            _transferInERC20(_token, _amount);
        }
        
        // 2. Actualizar balance interno del usuario
        s_balances[msg.sender][_token] += _amount;
        
        // 3. Actualizar el valor total en USD del banco
        totalDepositedUSD += depositUSD;
        
        // --- Events ---
        emit DepositSuccessful(msg.sender, _token, _amount, s_balances[msg.sender][_token]);
    }

    // -------------------------------------------------------------------------
    //                             HELPERS DE ORÁCULOS Y CONVERSIÓN
    // -------------------------------------------------------------------------
    
    /**
     * @dev Obtiene el valor actual de un token (o ETH) en USD.
     * @param _token La dirección del token (address(0) para ETH).
     * @param _amount La cantidad de tokens/ETH en unidades nativas.
     * @return El valor total en USD con 8 decimales.
     */
    function _getTokenValueInUSD(address _token, uint256 _amount) private view returns (uint256) {
        AggregatorV3Interface priceFeed;
        uint8 tokenDecimalsInternal;
        
        if (_token == address(0)) {
            priceFeed = ETH_USD_PRICE_FEED;
            tokenDecimalsInternal = 18; // ETH siempre tiene 18 decimales
        } else {
            // Requerir que el Price Feed y los decimales estén configurados
            priceFeed = tokenPriceFeeds[_token];
            tokenDecimalsInternal = tokenDecimals[_token];
            if (tokenDecimalsInternal == 0) revert DecimalsNotSet(_token);
        }

        // Obtener el precio del oráculo (retorna un precio con 8 decimales)
        (, int256 price, , , ) = priceFeed.latestRoundData();
        if (price <= 0) revert ChainlinkCallFailed();
        
        // Normalizar la cantidad para el cálculo. El resultado final debe ser en USD (8 decimales)
        // ValorUSD = (cantidad * precio) / 10^tokenDecimals
        
        // Usamos una biblioteca de FixedPointMath para cálculos seguros, pero por simplicidad de ejemplo:
        
        // 1. Multiplicar cantidad * precio (el resultado tendrá 18 + 8 = 26 decimales si fuera ETH)
        uint256 numerator = _amount * uint256(price);
        
        // 2. Dividir por 10^tokenDecimals (normaliza la cantidad)
        // El resultado final tiene (26 - tokenDecimals) decimales.
        
        // Queremos el resultado en 8 decimales (los decimales del precio Chainlink).
        // Para tener 8 decimales al final:
        // Si tokenDecimals < 8, multiplicamos por 10^(8 - tokenDecimals) para subir al precio feed
        // Si tokenDecimals > 8, dividimos por 10^(tokenDecimals - 8)
        
        // Opción Simple (asumiendo que los tokens que se integran tienen decimales <= 18):
        uint256 finalValueUSD;
        if (tokenDecimalsInternal > 8) {
             // Dividir por la diferencia de decimales (ej: 18 - 8 = 10)
             finalValueUSD = numerator / (10 ** (tokenDecimalsInternal - 8)); 
        } else if (tokenDecimalsInternal < 8) {
             // Multiplicar por la diferencia (ej: 6 - 8 = -2. Multiplicar por 10^2)
             finalValueUSD = numerator * (10 ** (8 - tokenDecimalsInternal));
        } else { // tokenDecimalsInternal == 8
             finalValueUSD = numerator;
        }

        return finalValueUSD / 10**8; // Dividir por 10^8 para obtener el resultado en la unidad básica del feed.
    }
    
    // -------------------------------------------------------------------------
    //                             HELPERS DE TRANSFERENCIA
    // -------------------------------------------------------------------------
    
    /**
     * @dev Realiza la transferencia de ERC-20 hacia el contrato (requiere aprobación previa).
     */
    function _transferInERC20(address _token, uint256 _amount) private {
        bool success = IERC20(_token).transferFrom(msg.sender, address(this), _amount);
        if (!success) {
            revert TransferFromFailed({token: _token, from: msg.sender, amount: _amount});
        }
    }

    /// @dev Envío seguro de Ether.
    function _safeTransferEther(address _to, uint256 _amount) private {
        (bool success, ) = payable(_to).call{value: _amount}("");
        if (!success) {
            revert ExternalTransferFailed({token: address(0), recipient: _to, amount: _amount});
        }
    }
    
    /// @dev Envío seguro de ERC-20.
    function _safeTransferERC20(address _token, address _to, uint256 _amount) private {
        bool success = IERC20(_token).transfer(_to, _amount);
        if (!success) {
            revert ExternalTransferFailed({token: _token, recipient: _to, amount: _amount});
        }
    }
    
    // -------------------------------------------------------------------------
    //                             FUNCIONES DE VISTA
    // -------------------------------------------------------------------------

    function getBalance(address _user, address _token) external view returns (uint256) {
        return s_balances[_user][_token];
    }
    
    function getLatestPrice(address _token) external view returns (int256) {
        AggregatorV3Interface priceFeed = (_token == address(0)) ? ETH_USD_PRICE_FEED : tokenPriceFeeds[_token];
        (, int256 price, , , ) = priceFeed.latestRoundData();
        return price;
    }
}
