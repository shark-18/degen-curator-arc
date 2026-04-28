"use client";

import { useState } from "react";
import { useAccount, useReadContracts, useWriteContract, useWaitForTransactionReceipt } from "wagmi";
import { parseUnits, formatUnits } from "viem";
import { PRINCIPAL_VAULT, PRINCIPAL_VAULT_ABI, USDC, ERC20_ABI } from "@/lib/contracts";

export function DepositForm() {
  const { address } = useAccount();
  const [amount, setAmount] = useState("");
  const { writeContract, data: txHash, isPending } = useWriteContract();
  const { isLoading: isMining } = useWaitForTransactionReceipt({ hash: txHash });

  const { data } = useReadContracts({
    contracts: [
      { address: USDC, abi: ERC20_ABI, functionName: "balanceOf", args: address ? [address] : undefined },
      { address: USDC, abi: ERC20_ABI, functionName: "allowance", args: address ? [address, PRINCIPAL_VAULT] : undefined },
      { address: PRINCIPAL_VAULT, abi: PRINCIPAL_VAULT_ABI, functionName: "minDeposit" },
    ],
    query: { enabled: !!address },
  });

  const usdcBalance = data?.[0]?.result as bigint | undefined;
  const allowance = data?.[1]?.result as bigint | undefined;
  const minDeposit = data?.[2]?.result as bigint | undefined;

  const amountWei = amount ? parseUnits(amount, 6) : 0n;
  const needsApproval = allowance !== undefined && amountWei > allowance;

  const onApprove = () => {
    writeContract({
      address: USDC,
      abi: ERC20_ABI,
      functionName: "approve",
      args: [PRINCIPAL_VAULT, amountWei],
    });
  };

  const onDeposit = () => {
    if (!address) return;
    writeContract({
      address: PRINCIPAL_VAULT,
      abi: PRINCIPAL_VAULT_ABI,
      functionName: "deposit",
      args: [amountWei, address],
    });
  };

  return (
    <div className="bg-surface border border-line p-6">
      <h3 className="text-sm text-muted uppercase tracking-wider mb-4">Deposit USDC</h3>
      {!address ? (
        <p className="text-muted text-sm">Connect wallet to deposit.</p>
      ) : (
        <div className="space-y-4">
          <div>
            <label className="block text-xs text-muted mb-2">
              USDC balance: {usdcBalance ? formatUnits(usdcBalance, 6) : "—"}
              {minDeposit && ` (min ${formatUnits(minDeposit, 6)})`}
            </label>
            <input
              type="number"
              value={amount}
              onChange={(e) => setAmount(e.target.value)}
              placeholder="100"
              className="w-full bg-bg border border-line p-3 text-ink focus:outline-none focus:border-accent"
            />
          </div>
          {needsApproval ? (
            <button
              onClick={onApprove}
              disabled={isPending || isMining || !amount}
              className="w-full bg-accent text-bg p-3 font-bold uppercase tracking-wider disabled:opacity-50"
            >
              {isPending || isMining ? "Approving..." : "Approve USDC"}
            </button>
          ) : (
            <button
              onClick={onDeposit}
              disabled={isPending || isMining || !amount}
              className="w-full bg-accent text-bg p-3 font-bold uppercase tracking-wider disabled:opacity-50"
            >
              {isPending || isMining ? "Depositing..." : "Deposit"}
            </button>
          )}
          <p className="text-xs text-muted">
            Worst case: principal returned. Best case: lottery pays out at TGE.
          </p>
        </div>
      )}
    </div>
  );
}
