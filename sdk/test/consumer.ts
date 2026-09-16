import {
  contracts,
  flapTaxTokenV3Abi,
  presaleAbi,
} from "@sillyfunc/launchpad-contracts";

type FunctionName<Abi extends readonly unknown[]> = Abi[number] extends infer Item
  ? Item extends { readonly type: "function"; readonly name: infer Name extends string }
    ? Name
    : never
  : never;

const coordinator = contracts[56].coordinatorFactory;

const coordinatorAddress: "0xc7284f96716E4FbB3F794CB407D882C29aA653B1" =
  coordinator.address;
const coordinatorFunction: FunctionName<typeof coordinator.abi> =
  "getTotalTokenCount";
const presaleFunction: FunctionName<typeof presaleAbi> = "getLaunchStatus";
const tokenFunction: FunctionName<typeof flapTaxTokenV3Abi> =
  "getPoolStateData";

void coordinatorAddress;
void coordinatorFunction;
void presaleFunction;
void tokenFunction;
