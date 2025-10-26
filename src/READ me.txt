Mejoras y su Beneficio
Soporte Multi-Token,"Escalabilidad: Se migró el almacenamiento a un mapeo anidado (usuario => token => balance), permitiendo depositar y retirar cualquier token ERC-20 además de ETH."
Oráculos Chainlink,Control de Riesgo y Seguridad: Los límites de depósito y retiro (BANK_CAP_USD y WITHDRAWAL_LIMIT_USD) se definen en USD y se validan en tiempo real usando los Price Feeds de Chainlink (oráculos de datos). Esto protege al banco de la volatilidad de los precios.
Conversión de Decimales,"Precisión Financiera: La lógica de cálculo (_getTokenValueInUSD) maneja automáticamente los diferentes decimales de cada token ERC-20 (ej. DAI tiene 18, USDC tiene 6) para convertirlos a un valor uniforme en USD (8 decimales), asegurando que los límites sean precisos."
Control de Acceso (Ownable),"Administración Segura: Se implementó el contrato Ownable de OpenZeppelin para restringir funciones críticas (ej. setTokenPriceFeed, setTokenDecimals) únicamente a la dirección que desplegó el contrato (el Dueño)."
Seguridad de Código,"Robustez: Se aplicaron patrones como Checks-Effects-Interactions (CEI) en las funciones de retiro, el modificador nonReentrant para prevenir ataques de reentrada, y el uso extensivo de Errores Personalizados para mejorar la eficiencia del gas y la depuración (debugging)."

Instrucciones de Despliegue (Sepolia Testnet)
El despliegue se realiza a través de Remix IDE, requiriendo tres parámetros esenciales para el constructor.

Requisitos Previos
MetaMask Conectado: Asegúrate de que tu billetera MetaMask esté configurada en la red de prueba Sepolia.

Fondos de Gas: Tu billetera debe tener ETH de prueba (obtenido de un faucet) para pagar la tarifa de gas del despliegue.

Archivos: Los archivos KipuBank_Chainlink.sol y AggregatorV3Interface.sol deben estar en tu espacio de trabajo de Remix.

Parámetros del Constructor

_bankCapUSD  1000000000000 Límite Máximo del Banco: $10,000 USD (con $10^8$ decimales)
_withdrawalLimitUSD  100000000  Límite Máximo de Retiro por Tx: $100 USD (con $10^8$ decimales)
_ethPriceFeed0x694aa1769357215ef4beca98fc2d90aac5e26ce4  Dirección del Price Feed de ETH/USD en Sepolia

