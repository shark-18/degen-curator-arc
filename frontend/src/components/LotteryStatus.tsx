"use client";

import { useReadContracts } from "wagmi";
import { formatUnits } from "viem";
import { LOTTERY_TREASURY, LOTTERY_TREASURY_ABI } from "@/lib/contracts";

export function LotteryStatus() {
  const { data } = useReadContracts({
    contracts: [
      { address: LOTTERY_TREASURY, abi: LOTTERY_TREASURY_ABI, functionName: "cumulativeYieldSwept" },
      { address: LOTTERY_TREASURY, abi: LOTTERY_TREASURY_ABI, functionName: "cumulativeStrategySpend" },
      { address: LOTTERY_TREASURY, abi: LOTTERY_TREASURY_ABI, functionName: "totalAssetsAtRisk" },
      { address: LOTTERY_TREASURY, abi: LOTTERY_TREASURY_ABI, functionName: "globalShareIndex" },
    ],
  });

  const swept = (data?.[0]?.result ?? 0n) as bigint;
  const spend = (data?.[1]?.result ?? 0n) as bigint;
  const atRisk = (data?.[2]?.result ?? 0n) as bigint;
  const idx = (data?.[3]?.result ?? 0n) as bigint;

  return (
    <div className="bg-surface border border-line p-6">
      <h3 className="text-sm text-muted uppercase tracking-wider mb-4">Lottery Treasury</h3>
      <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
        <Stat label="Yield Swept" value={`$${Number(formatUnits(swept, 6)).toLocaleString()}`} />
        <Stat label="Deployed" value={`$${Number(formatUnits(spend, 6)).toLocaleString()}`} />
        <Stat label="In YTs" value={`$${Number(formatUnits(atRisk, 6)).toLocaleString()}`} />
        <Stat label="Share Index" value={(Number(idx) / 1e30).toFixed(6)} />
      </div>
    </div>
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <div className="text-xs text-muted mb-1">{label}</div>
      <div className="text-lg text-accent">{value}</div>
    </div>
  );
}
