"use client";

import { useReadContracts } from "wagmi";
import { formatUnits } from "viem";
import { PRINCIPAL_VAULT, PRINCIPAL_VAULT_ABI } from "@/lib/contracts";

export function CapCounter() {
  const { data } = useReadContracts({
    contracts: [
      { address: PRINCIPAL_VAULT, abi: PRINCIPAL_VAULT_ABI, functionName: "principalHighWater" },
      { address: PRINCIPAL_VAULT, abi: PRINCIPAL_VAULT_ABI, functionName: "depositCap" },
      { address: PRINCIPAL_VAULT, abi: PRINCIPAL_VAULT_ABI, functionName: "depositorCount" },
      { address: PRINCIPAL_VAULT, abi: PRINCIPAL_VAULT_ABI, functionName: "depositorCap" },
    ],
  });

  const hwm = data?.[0]?.result ? Number(formatUnits(data[0].result as bigint, 6)) : 0;
  const cap = data?.[1]?.result ? Number(formatUnits(data[1].result as bigint, 6)) : 1_000_000;
  const count = data?.[2]?.result ? Number(data[2].result as bigint) : 0;
  const maxCount = data?.[3]?.result ? Number(data[3].result as bigint) : 1000;

  const tvlPct = Math.min(100, (hwm / cap) * 100);
  const depositorPct = Math.min(100, (count / maxCount) * 100);

  return (
    <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
      <Counter
        label="Vault TVL"
        value={`$${hwm.toLocaleString()}`}
        max={`/ $${cap.toLocaleString()}`}
        pct={tvlPct}
      />
      <Counter
        label="Depositors"
        value={count.toString()}
        max={`/ ${maxCount}`}
        pct={depositorPct}
      />
    </div>
  );
}

function Counter({ label, value, max, pct }: { label: string; value: string; max: string; pct: number }) {
  return (
    <div className="bg-surface border border-line p-6">
      <div className="text-xs text-muted uppercase tracking-wider mb-2">{label}</div>
      <div className="flex items-baseline gap-2 mb-3">
        <span className="text-3xl font-bold text-accent">{value}</span>
        <span className="text-sm text-muted">{max}</span>
      </div>
      <div className="h-1.5 bg-line">
        <div className="h-full bg-accent transition-all duration-500" style={{ width: `${pct}%` }} />
      </div>
      <div className="text-xs text-muted mt-2">{pct.toFixed(1)}% filled</div>
    </div>
  );
}
