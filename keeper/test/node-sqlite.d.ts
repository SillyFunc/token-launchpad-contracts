// 测试专用：仅声明本仓库用到的 node:sqlite 子集，避免为测试引入 @types/node 依赖。
// 运行时若 Node 版本不支持 node:sqlite，测试会自动跳过（见 signer.test.ts）。
declare module "node:sqlite" {
  export class DatabaseSync {
    constructor(path: string);
    exec(sql: string): void;
    prepare(sql: string): {
      all(...params: unknown[]): unknown[];
      run(...params: unknown[]): unknown;
    };
  }
}
