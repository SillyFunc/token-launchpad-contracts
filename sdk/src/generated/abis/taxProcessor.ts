// AUTO-GENERATED FILE. DO NOT EDIT.

export const taxProcessorAbi = [
  {
    "type": "constructor",
    "inputs": [
      {
        "name": "keeperRegistry_",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "receive",
    "stateMutability": "payable"
  },
  {
    "type": "function",
    "name": "KEEPER_ROLE",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "MAX_DEADLINE_DELAY",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint64",
        "internalType": "uint64"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "commissionBps",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint16",
        "internalType": "uint16"
      }
    ],
    "stateMutability": "pure"
  },
  {
    "type": "function",
    "name": "commissionQuoteBalance",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "pure"
  },
  {
    "type": "function",
    "name": "commissionReceiver",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "pure"
  },
  {
    "type": "function",
    "name": "converter",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "pure"
  },
  {
    "type": "function",
    "name": "dispatch",
    "inputs": [],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "dividendAddress",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "pure"
  },
  {
    "type": "function",
    "name": "dividendQuoteBalance",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "pure"
  },
  {
    "type": "function",
    "name": "dividendToken",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "pure"
  },
  {
    "type": "function",
    "name": "dividendTokenBalance",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "pure"
  },
  {
    "type": "function",
    "name": "feeConfig",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "tuple",
        "internalType": "struct PackedFeeConfig",
        "components": [
          {
            "name": "marketBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "deflationBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "lpBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "dividendBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "feeRate",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "isWeth",
            "type": "bool",
            "internalType": "bool"
          }
        ]
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "feeConfigV2",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "tuple",
        "internalType": "struct PackedFeeConfigV2",
        "components": [
          {
            "name": "marketBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "deflationBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "lpBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "dividendBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "feeRate",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "isWeth",
            "type": "bool",
            "internalType": "bool"
          },
          {
            "name": "commissionBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "dividendToken",
            "type": "address",
            "internalType": "address"
          }
        ]
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "feeQuoteBalance",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "pure"
  },
  {
    "type": "function",
    "name": "feeReceiver",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "flapBlackHole",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "pure"
  },
  {
    "type": "function",
    "name": "getQuoteToken",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "initialize",
    "inputs": [
      {
        "name": "params",
        "type": "tuple",
        "internalType": "struct TaxProcessorInitParams",
        "components": [
          {
            "name": "quoteToken",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "router",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "feeReceiver",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "marketAddress",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "dividendAddress",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "taxToken",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "feeRate",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "marketBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "deflationBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "lpBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "dividendBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "dividendToken",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "commissionReceiver",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "commissionBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "converter",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "liqExpectedOutputAmount",
            "type": "uint256",
            "internalType": "uint256"
          }
        ]
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "isWeth",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "keeperRegistry",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "liqExpectedOutputAmount",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "lpQuoteBalance",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "pure"
  },
  {
    "type": "function",
    "name": "marketAddress",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "pure"
  },
  {
    "type": "function",
    "name": "marketQuoteBalance",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "pure"
  },
  {
    "type": "function",
    "name": "pendingDirection",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "int8",
        "internalType": "int8"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "pendingDividendQuoteTokenBalance",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "pure"
  },
  {
    "type": "function",
    "name": "pendingTaxTokens",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "processBondingCurveTax",
    "inputs": [
      {
        "name": "quoteAmount",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "processPendingTax",
    "inputs": [
      {
        "name": "amountIn",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "minQuoteOut",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "deadline",
        "type": "uint64",
        "internalType": "uint64"
      }
    ],
    "outputs": [
      {
        "name": "out",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "processTaxTokens",
    "inputs": [
      {
        "name": "taxAmount",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "int8",
        "internalType": "int8"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "quoteToken",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "requiresMEVProtection",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "pure"
  },
  {
    "type": "function",
    "name": "router",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "swapRegistry",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "taxToken",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "totalDividendTokenSent",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "pure"
  },
  {
    "type": "function",
    "name": "totalQuoteAddedToLiquidity",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "pure"
  },
  {
    "type": "function",
    "name": "totalQuoteSentToDividend",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "pure"
  },
  {
    "type": "function",
    "name": "totalQuoteSentToMarketing",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "pure"
  },
  {
    "type": "function",
    "name": "totalQuoteSentToReceiver",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "totalTokenAddedToLiquidity",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "pure"
  },
  {
    "type": "function",
    "name": "weth",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "event",
    "name": "Initialized",
    "inputs": [
      {
        "name": "taxToken",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "TaxForwarded",
    "inputs": [
      {
        "name": "receiver",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "amount",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "isNative",
        "type": "bool",
        "indexed": false,
        "internalType": "bool"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "TaxProcessed",
    "inputs": [
      {
        "name": "taxAmount",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "quoteOut",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "direction",
        "type": "int8",
        "indexed": false,
        "internalType": "int8"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "TaxQueued",
    "inputs": [
      {
        "name": "taxAmount",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "pendingBalance",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "error",
    "name": "AlreadyInitialized",
    "inputs": []
  },
  {
    "type": "error",
    "name": "ApproveFailed",
    "inputs": [
      {
        "name": "token",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "spender",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "FeeReceiverRequired",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InsufficientQuoteOutput",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidProcessingDeadline",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidTaxAmount",
    "inputs": []
  },
  {
    "type": "error",
    "name": "KeeperRegistryRequired",
    "inputs": []
  },
  {
    "type": "error",
    "name": "NotDeployer",
    "inputs": []
  },
  {
    "type": "error",
    "name": "NotTaxToken",
    "inputs": []
  },
  {
    "type": "error",
    "name": "QuoteTokenUnavailable",
    "inputs": []
  },
  {
    "type": "error",
    "name": "RouterRequired",
    "inputs": []
  },
  {
    "type": "error",
    "name": "TaxTokenRequired",
    "inputs": []
  },
  {
    "type": "error",
    "name": "TransferFailed",
    "inputs": [
      {
        "name": "token",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "to",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "TransferFromFailed",
    "inputs": [
      {
        "name": "token",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "from",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "to",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "UnauthorizedTaxKeeper",
    "inputs": []
  },
  {
    "type": "error",
    "name": "UnsafeMinQuoteOut",
    "inputs": []
  }
] as const;
