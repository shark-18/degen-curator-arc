"use client";

import { useAccount, useReadContracts, useWriteContract, useWaitForTransactionReceipt } from "wagmi";
import { formatUnits } from "viem";
import {
  PRINCIPAL_VAULT,
  PRINCIPAL_VAULT_ABI,
  LOTTERY_TREASURY,
  LOTTERY_TREASURY_ABI,
} from "@/lib/contracts";

export function UserPosition() {
  const { address } = useAccount();
  const { writeContract, data: txHash, isPending } = useWriteContract();
  const { isLoading: isMining } = useWaitForTransactionReceipt({ hash: txHash });

  const { data } = useReadContracts({
    contracts: [
      { address: PRINCIPAL_VAULT, abi: PRINCIPAL_VAULT_ABI, functionName: "balanceOf", args: address ? [address] : undefined },
      { address: PRINCIPAL_VAULT, abi: PRINCIPAL_VAULT_ABI, functionName: "convertToAssets", args: [10n ** 18n] },
      { address: LOTTERY_TREASURY, abi: LOTTERY_TREASURY_ABI, functionName: "claimableOf", args: address ? [address] : undefined },
      { address: LOTTERY_TREASURY, abi: LOTTERY_TREASURY_ABI, functionName: "userFirstHoldTimestamp", args: address ? [address] : undefined },
    ],
    query: { enabled: !!address },
  });

  const shares = (data?.[0]?.result ?? 0n) as bigint;
  // pricePerShare is intentionally fixed at 1:1 USDC:share (modulo virtual offset)
  const principalUsdc = (data?.[0]?.result ?? 0n) as bigint; // 1:1 with shares due to C-2 fix
  const claimable = (data?.[2]?.result ?? 0n) as bigint;
  const firstHold = (data?.[3]?.result ?? 0n) as bigint;

  const lockupDuration = 86400n; // 1 day
  const lockupExpires = firstHold > 0n ? firstHold + lockupDuration : 0n;
  const inLockup = firstHold > 0n && BigInt(Math.floor(Date.now() / 1000)) < lockupExpires;

  const onRedeem = () => {
    if (!address || shares === 0n) return;
    writeContract({
      address: PRINCIPAL_VAULT,
      abi: PRINCIPAL_VAULT_ABI,
      functionName: "redeem",
      args: [shares, address, address],
    });
  };

  const onClaim = () => {
    writeContract({
      address: LOTTERY_TREASURY,
      abi: LOTTERY_TREASURY_ABI,
      functionName: "claim",
    });
  };

  return (
    <div className="bg-surface border border-line p-6">
      <h3 className="text-sm text-muted uppercase tracking-wider mb-4">Your Position</h3>
      {!address ? (
        <p className="text-muted text-sm">Connect wallet to view position.</p>
      ) : (
        <div className="space-y-4">
          <Row label="dCURATOR shares" value={formatUnits(shares, 12)} />
          <Row label="Principal (USDC)" value={`$${Number(formatUnits(principalUsdc, 6)).toLocaleString()}`} />
          <Row label="Claimable lottery" value={`$${Number(formatUnits(claimable, 6)).toFixed(2)}`} />
          {inLockup && (
            <Row label="Lockup ends" value={new Date(Number(lockupExpires) * 1000).toLocaleString()} />
          )}

          <div className="pt-4 border-t border-line space-y-2">
            <button
              onClick={onClaim}
              disabled={claimable === 0n || isPending || isMining}
              className="w-full border border-accent text-accent p-3 uppercase tracking-wider disabled:opacity-30"
            >
              {claimable === 0n ? "Nothing to claim" : `Claim $${Number(formatUnits(claimable, 6)).toFixed(2)}`}
            </button>
            <button
              onClick={onRedeem}
              disabled={shares === 0n || isPending || isMining}
              className="w-full border border-line text-ink p-3 uppercase tracking-wider disabled:opacity-30"
            >
              Withdraw All Principal
            </button>
          </div>
        </div>
      )}
    </div>
  );
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex justify-between text-sm">
      <span className="text-muted">{label}</span>
      <span className="text-ink">{value}</span>
    </div>
  );
}
