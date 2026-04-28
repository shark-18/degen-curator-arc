import { getDefaultConfig } from "@rainbow-me/rainbowkit";
import { base, baseSepolia } from "wagmi/chains";

export const wagmiConfig = getDefaultConfig({
  appName: "Degen Curator",
  projectId: process.env.NEXT_PUBLIC_WC_PROJECT_ID || "00000000000000000000000000000000",
  chains: [base, baseSepolia],
  ssr: true,
});

export const CHAIN_ID = process.env.NEXT_PUBLIC_CHAIN === "base" ? base.id : baseSepolia.id;
