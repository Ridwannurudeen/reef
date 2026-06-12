export interface CanExecuteResult {
  allowed: boolean;
  reason: string;
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
  apiBase?: string;
}

export function encodeCanExecute(
  agentId: bigint | number | string,
  asset: string,
  sizeBps: bigint | number | string,
): string;
export function decodeCanExecute(hex: string): CanExecuteResult;
export function encodeScoreOf(agentId: bigint | number | string): string;
export function encodeReport(
  agentId: bigint | number | string,
  asset: string,
  sizeBps: bigint | number | string,
): string;
export function decodeReport(hex: string): TrustReport;
export function wadToScore(wad: bigint | string): number;

export class ReefClient {
  constructor(opts?: ReefClientOptions);
  canExecute(
    agentId: bigint | number | string,
    asset: string,
    sizeBps: bigint | number | string,
  ): Promise<CanExecuteResult>;
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
}

export default ReefClient;
