KipuBankV3

KipuBankV3 es una versión avanzada del contrato, diseñada para manejar depósitos en ETH o tokens ERC20 y convertirlos automáticamente a USDC mediante Uniswap.
Además, incorpora compatibilidad con Permit2, mejoras en seguridad y mantiene el control de capacidad total del banco expresada en USD.

Mejoras realizadas:

Integración con Uniswap:

Permite convertir automáticamente los depósitos en ETH o tokens ERC20 a USDC.

Uso del router de Uniswap V2 para realizar los intercambios.

Cálculo estimado del valor en USDC antes de ejecutar el swap.

Compatibilidad con Permit2:

Facilita transferencias seguras sin necesidad de múltiples aprobaciones.

Mejora la eficiencia en el uso de tokens.

Depósitos y Retiros Unificados:

ETH y tokens ERC20 gestionados bajo la misma estructura de contabilidad.

Todos los balances se expresan en USDC.

Validación de límites mínimos y máximos por operación.

Seguridad y Control de Acceso:

DEFAULT_ADMIN_ROLE: gestiona parámetros globales como bankCapUSD.

PAUSER_ROLE: puede pausar depósitos y retiros ante una emergencia.

ReentrancyGuard para evitar ataques de reentrada.

Contabilidad Interna y Límite Global:

Los valores de los depósitos se convierten a USD según su precio o tipo de cambio.

Control del total del banco (totalBankUSD) frente al límite permitido (bankCapUSD).

Despliegue

Clonar o descargar el proyecto desde GitHub.

Abrir el archivo KipuBankV3.sol en Remix IDE.

Compilar el contrato seleccionando la versión de Solidity 0.8.30.

Desplegar el contrato especificando los parámetros del constructor:

constructor(
    uint256 _bankCapUSD,
    address _uniswapRouter,
    address _usdc,
    address _permit2
)

Contrato verificado en etherscan:
https://sepolia.etherscan.io/address/0x38379866e426e3632dbC9CA8961d031871f5ABF7#code
