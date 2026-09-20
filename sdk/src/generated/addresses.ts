// AUTO-GENERATED FILE. DO NOT EDIT.

export const addresses = {
  56: {
    flapTaxTokenImplementation: "0xd7E12EcD6406B993d94F0bC67A4a62681F50AA99",
    tokenFactory: "0x04556cBC53C9E994522b008B676958e715545564",
    presaleImplementation: "0x6b51064d62018DE9832590f1788078BdFB64ACa5",
    presaleFactory: "0x7A6B4da821F4b2aDB1432E06E7B7aD2f20972A1A",
    coordinatorFactory: "0xc7284f96716E4FbB3F794CB407D882C29aA653B1",
  },
  97: {
    flapTaxTokenImplementation: "0x52c01A724b80d2E408131466802ec05FeB5557da",
    tokenFactory: "0xfE39e0fe0CbE1c2A042c337880161B9aeF2D2Eb9",
    presaleImplementation: "0x9B1c041844e2334478DC1135cd051A3CbC3bC961",
    presaleFactory: "0xd2E0861A80C4a3b0bdf501251Ee397476437138c",
    coordinatorFactory: "0x9a7594114f4b79544f7CA00FBd1E902C556BbC47",
    buybackVaultImplementation: "0x4390656F8560Df63E3551A32eac6c97e1F36D2FD",
    buybackVaultFactory: "0xf1bD2178266aa91270c888808f71a842cdE037fC",
  },
} as const;

export type SupportedChainId = keyof typeof addresses;
export type DeploymentAddresses = (typeof addresses)[SupportedChainId];
