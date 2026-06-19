export interface CanExecuteResult {
  allowed: boolean;
  reason: string;
}

export interface ActionInput {
  target: string;
  value?: bigint | number | string;
  data?: string;
  asset: string;
  portfolioValue: bigint | number | string;
}

export interface CanExecuteActionResult extends CanExecuteResult {
  amount: bigint;
  sizeBps: number;
}

export interface TrustReport {
  score: number;
  rating: string;
  guardCleared: boolean;
  guardReason: string;
}

export interface AgentPassport {
  agentId: number;
  trustScore: number | null;
  rating: string | null;
  components: Record<string, number> | null;
  reputationE18: string | null;
  navE18: string | null;
  bondE18: string | null;
  bonded: boolean | null;
  receiptAgeSec: number | null;
  vault: string | null;
  reefGuard: { allowed: boolean; reason: string } | null;
  allocation: { qualified: boolean; targetWeightBps: number } | null;
  activeMandate: number | null;
  latestDecision: {
    action: string;
    source: string;
    model: string | null;
    reasoning: string;
    txHash: string | null;
    ts: number;
  } | null;
  updatedAt: number;
}

export interface ReefClientOptions {
  rpcUrl?: string;
  guardAddress?: string;
  oracleAddress?: string;
  identityAddress?: string;
  indexAddress?: string;
  bondAddress?: string;
  registryAddress?: string;
  apiBase?: string;
  provider?: Eip1193Provider;
  account?: string;
}

export interface Eip1193Provider {
  request(args: { method: string; params?: unknown[] }): Promise<unknown>;
}

export interface TransactionRequest {
  to?: string;
  data: string;
  value?: bigint | number | string;
  from?: string;
  provider?: Eip1193Provider;
  gas?: bigint | number | string;
}

export function encodeCanExecute(
  agentId: bigint | number | string,
  asset: string,
  sizeBps: bigint | number | string,
): string;
export function decodeCanExecute(hex: string): CanExecuteResult;
export function encodeCanExecuteAction(
  agentId: bigint | number | string,
  action: ActionInput,
): string;
export function decodeCanExecuteAction(hex: string): CanExecuteActionResult;
export function encodeScoreOf(agentId: bigint | number | string): string;
export function encodeReport(
  agentId: bigint | number | string,
  asset: string,
  sizeBps: bigint | number | string,
): string;
export function decodeReport(hex: string): TrustReport;
export function wadToScore(wad: bigint | string): number;
export function encodeRegisterAgent(): string;
export function encodeSetReputationSource(
  agentId: bigint | number | string,
  source: string,
): string;
export function encodeApproveAdapter(adapter: string): string;
export function encodeApproveStrategy(adapter: string): string;
export function encodeErc20Approve(
  spender: string,
  amount: bigint | number | string,
): string;
export function encodePostBond(
  agentId: bigint | number | string,
  amount: bigint | number | string,
): string;
export function encodeSelfListVault(vault: string): string;
export function encodePublishReceipt(
  seq: bigint | number | string,
  evidenceHash: string,
  claimedDelta: bigint | number | string,
  period: bigint | number | string,
  signature: string,
): string;
export function encodeDeployVault(
  bytecode: string,
  asset: string,
  agentId: bigint | number | string,
  identity: string,
  registry: string,
): string;

export class ReefClient {
  constructor(opts?: ReefClientOptions);
  canExecute(
    agentId: bigint | number | string,
    asset: string,
    sizeBps: bigint | number | string,
  ): Promise<CanExecuteResult>;
  canExecuteAction(
    agentId: bigint | number | string,
    action: ActionInput,
  ): Promise<CanExecuteActionResult>;
  trustScoreOf(agentId: bigint | number | string): Promise<number>;
  report(
    agentId: bigint | number | string,
    asset: string,
    sizeBps: bigint | number | string,
  ): Promise<TrustReport>;
  passport(agentId: number | string): Promise<AgentPassport>;
  score(agentId: number | string): Promise<number | null>;
  latestReceipt(
    agentId: number | string,
  ): Promise<AgentPassport["latestDecision"]>;
  requestTransaction(tx: TransactionRequest): Promise<unknown>;
  registerAgent(opts?: {
    identityAddress?: string;
    from?: string;
    provider?: Eip1193Provider;
  }): Promise<unknown>;
  setReputationSource(opts: {
    identityAddress?: string;
    agentId: bigint | number | string;
    source: string;
    from?: string;
    provider?: Eip1193Provider;
  }): Promise<unknown>;
  deployVault(opts: {
    bytecode: string;
    asset: string;
    agentId: bigint | number | string;
    identityAddress?: string;
    registryAddress?: string;
    from?: string;
    provider?: Eip1193Provider;
  }): Promise<unknown>;
  approveAdapter(opts: {
    registryAddress?: string;
    adapter: string;
    from?: string;
    provider?: Eip1193Provider;
  }): Promise<unknown>;
  approveStrategy(opts: {
    vaultAddress: string;
    adapter: string;
    from?: string;
    provider?: Eip1193Provider;
  }): Promise<unknown>;
  approveToken(opts: {
    tokenAddress: string;
    spender: string;
    amount: bigint | number | string;
    from?: string;
    provider?: Eip1193Provider;
  }): Promise<unknown>;
  postBond(opts: {
    bondAddress?: string;
    agentId: bigint | number | string;
    amount: bigint | number | string;
    from?: string;
    provider?: Eip1193Provider;
  }): Promise<unknown>;
  selfListVault(opts: {
    indexAddress?: string;
    vault: string;
    from?: string;
    provider?: Eip1193Provider;
  }): Promise<unknown>;
  publishReceipt(opts: {
    vaultAddress: string;
    seq: bigint | number | string;
    evidenceHash: string;
    claimedDelta: bigint | number | string;
    period: bigint | number | string;
    signature: string;
    from?: string;
    provider?: Eip1193Provider;
  }): Promise<unknown>;
}

export default ReefClient;
