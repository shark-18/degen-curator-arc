"use client";

import { ConnectButton } from "@rainbow-me/rainbowkit";
import { CapCounter } from "@/components/CapCounter";
import { DepositForm } from "@/components/DepositForm";
import { UserPosition } from "@/components/UserPosition";
import { LotteryStatus } from "@/components/LotteryStatus";

export default function Home() {
  return (
    <main className="min-h-screen bg-bg text-ink p-6 md:p-12 font-mono">
      <div className="max-w-5xl mx-auto">
        <header className="flex items-center justify-between mb-12 pb-6 border-b border-line">
          <div>
            <h1 className="text-2xl font-bold text-white">DEGEN CURATOR</h1>
            <p className="text-sm text-muted mt-1">
              No-loss convex lottery on the Morpho stack.
            </p>
          </div>
          <ConnectButton />
        </header>

        <section className="mb-12">
          <div className="bg-surface border border-line p-8">
            <h2 className="text-xl text-accent uppercase tracking-wider mb-4">The Pitch</h2>
            <p className="text-ink leading-relaxed">
              Deposit USDC. Your principal sits 100% in a curated Morpho USDC vault — no leverage,
              no liquidation risk. Each week, the accrued yield is deployed into a basket of Pendle
              Points YTs picked by the curator. Worst case: you forego the yield. Best case: a YT
              hits TGE and pays out pro-rata to all depositors.
            </p>
            <ul className="text-sm text-muted mt-4 space-y-1">
              <li>{"›"} Principal: 100% in Morpho USDC vault. Always withdrawable.</li>
              <li>{"›"} Yield: streams to a separate lottery treasury. Nothing else.</li>
              <li>{"›"} Strategy: V2 filter (cheap-FDV + 30d momentum). 877% modeled treasury return.</li>
              <li>{"›"} Cap: limited initial spots. FOMO is the feature.</li>
            </ul>
          </div>
        </section>

        <section className="mb-12">
          <CapCounter />
        </section>

        <section className="grid grid-cols-1 md:grid-cols-2 gap-6 mb-12">
          <DepositForm />
          <UserPosition />
        </section>

        <section className="mb-12">
          <LotteryStatus />
        </section>

        <footer className="border-t border-line pt-6 text-xs text-muted">
          <p>
            Built by Innflux / credit.dollar.{" "}
            <a
              href="https://github.com/shark-18/degen-curator-arc"
              className="text-accent hover:underline"
            >
              Open source on GitHub
            </a>
            . Not financial advice. Audited by 4 Pashov-style sub-agents (5 critical findings
            fixed). 31/31 tests pass.
          </p>
        </footer>
      </div>
    </main>
  );
}
