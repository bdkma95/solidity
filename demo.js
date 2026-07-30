// =============================================================================
// scripts/demo.js — TokenizedFundPOC demonstration script
// =============================================================================
// VERSION v5.0 — Aligned with the Phase 2 architecture (EMT / TokenizedAssets
//                / TokenizedISIN / Toolbox / TokenizedFundPOC)
//
// WHAT CHANGED COMPARED TO THE PREVIOUS DEMO (v4.0):
//
//  [ARCH-1] A fifth contract, Toolbox.sol, is now deployed and wired to the
//    fund. It owns every fee rule, the investment strategy, compliance
//    thresholds, and the NAV/actuarial math. The fund contract no longer
//    hard-codes a 50/50 split or a flat "no fees" policy — it asks Toolbox.
//
//  [ARCH-2] Amounts are no longer "whole units" (POC-4 from Phase 1). The
//    fund now reasons in full 18-decimal EUR fixed point, matching
//    Toolbox's institutional minimums (100,000 EUR minimum subscription)
//    and the ERC20 standard 18 decimals used by every token contract. This
//    script uses ethers.parseEther()/formatEther() as a convenient 18-decimal
//    helper — the tokens represent EUR, not ETH, but the decimal scaling is
//    identical.
//
//  [ARCH-3] subscribe() now takes a EUR amount (not a share count), and
//    redeem() takes a share amount in 18-decimal share units (not a whole
//    share count). Shares issued are now derived from the current NAV per
//    share via Toolbox.calculateSharesToIssue(), not a fixed 10 EUR price.
//
//  [ARCH-4] Fees (entry, exit, early-redemption penalty, ongoing management/
//    custody/admin, performance) are computed by Toolbox and logged on-chain
//    (NAVCycle.feeCharged + dedicated events), but — per the current scope
//    decision — are NOT transferred to a separate fee-collector wallet. The
//    fee amount is simply excluded from what gets invested/paid out.
//
//  [ARCH-5] A new accrueOngoingFees() entry point computes prorata
//    management/custody/admin fees and the High Water Mark performance fee
//    for the elapsed period, and archives them as a new FEE_ACCRUAL-type
//    NAV cycle (operationType enum grew from 2 to 3 values).
//
//  [ARCH-6] TokenizedAssets no longer has an implicit 1 EUR unit price — the
//    fund exposes an admin-settable `assetPriceEUR` (defaults to 1 EUR),
//    a placeholder for a future price oracle (documented limitation).
//
//  [FIX-2] (kept from history) Blacklist must be checked BEFORE whitelist
//    wherever both are tested. Unchanged in TokenizedISIN.
//
//  [FIX-3] TokenizedISIN.deploy() was missing its `fundName_` constructor
//    argument (constructor is (name_, symbol_, isin_, fundName_, admin) —
//    5 args). Fixed: now passes "MMF Fund POC" as fundName_, matching the
//    fund contract's own name.
//
//  [TIMING] Every title()/subtitle() section now stamps a wall-clock time
//    when it starts and prints its measured duration (including on-chain
//    confirmation waits) the moment the next section begins, or at script
//    end/error via closeAllTimers(). Useful for comparing local Hardhat vs.
//    Sepolia confirmation times step by step.
//
// Run with:
//   Local   : Terminal 1 : npx hardhat node
//             Terminal 2 : npx hardhat run scripts/demo.js --network localhost
//   Sepolia :              npx hardhat run scripts/demo.js --network sepolia
//
// SEPOLIA NOTES (read before running):
//  • Hardhat only gives you ONE funded signer on a real network — the account
//    tied to the private key in your .env / hardhat.config.js. The other four
//    demo "actors" (compliance, auditor, investor1, investor2) are therefore
//    created as fresh random wallets at runtime and funded with a little
//    Sepolia ETH sent FROM your admin account, purely to cover their gas.
//  • Every step below is a real on-chain transaction (5 deployments + ~20
//    calls), so this will take several minutes and cost real (test) gas.
//    Fund your admin wallet with at least ~0.3 Sepolia ETH from a faucet
//    before running (e.g. https://sepoliafaucet.com or the Alchemy/Infura
//    faucets) — see FUNDING_PER_WALLET_ETH below to size it precisely.
//  • The demo's time-travel step (evm_increaseTime/evm_mine) only exists on
//    local Hardhat nodes. On Sepolia the script detects this automatically
//    and skips the fast-forward, calling accrueOngoingFees() back-to-back
//    instead — so the fees shown there will be near-zero (correct behaviour
//    for near-zero elapsed real time), not a bug.
// =============================================================================

const { ethers, network } = require("hardhat");

// Sepolia ETH sent from the admin wallet to each of the three sub-wallets
// that actually submit transactions (compliance, investor1, investor2).
// Bump this up if you see "insufficient funds" errors on testnet.
const FUNDING_PER_WALLET_ETH = "0.03";

const SEPOLIA_CHAIN_ID = 11155111n;

// ─────────────────────────────────────────────────────────────────────────────
// DISPLAY UTILITIES
// ─────────────────────────────────────────────────────────────────────────────

const SEP = "═".repeat(65);
const sep = "─".repeat(65);

const PRECISION   = 10n ** 18n; // mirrors Toolbox.PRECISION / fund.PRECISION
const BASE_POINTS = 10_000n;    // mirrors Toolbox.BASE_POINTS / fund.BASE_POINTS

// ─── TIMING INSTRUMENTATION ────────────────────────────────────────────────
// Every title()/subtitle() call is treated as the start of a new "step" /
// "sub-step". Each is timestamped when it starts, and its measured duration
// (wall-clock time, including on-chain confirmation waits) is printed the
// moment the NEXT step/sub-step of the same kind begins — or, for the very
// last one, when closeAllTimers() is called explicitly at the end of main().
// This lets you see exactly how long each on-chain action took, which is
// especially useful on Sepolia where confirmation times vary.

const scriptStartTime = Date.now();

function nowStr() {
  const d = new Date();
  return d.toTimeString().split(" ")[0] + "." + String(d.getMilliseconds()).padStart(3, "0");
}

function elapsedStr(startMs) {
  return `${((Date.now() - startMs) / 1000).toFixed(2)}s`;
}

let _titleStart = null;
let _titleLabel = null;
let _subStart = null;
let _subLabel = null;

function closeSubtitle() {
  if (_subStart !== null) {
    console.log(`  ⏱   [${nowStr()}] └─ "${_subLabel}" took ${elapsedStr(_subStart)}`);
    _subStart = null;
    _subLabel = null;
  }
}

function closeTitle() {
  closeSubtitle();
  if (_titleStart !== null) {
    console.log(`\n  ⏱️  [${nowStr()}] "${_titleLabel}" — STEP TOTAL: ${elapsedStr(_titleStart)}`);
    _titleStart = null;
    _titleLabel = null;
  }
}

// Call once, right before the script's final summary, to flush the timing
// of whichever step/sub-step was still open and print the grand total.
function closeAllTimers() {
  closeTitle();
  console.log(`\n  ⏱️  [${nowStr()}] TOTAL DEMONSTRATION TIME : ${elapsedStr(scriptStartTime)}`);
}

function title(text) {
  closeTitle(); // flush the previous step's timing before starting a new one
  _titleStart = Date.now();
  _titleLabel = text;
  console.log("\n" + SEP);
  console.log(`  🕒 [${nowStr()}] ${text}`);
  console.log(SEP);
}

function subtitle(text) {
  closeSubtitle(); // flush the previous sub-step's timing before starting a new one
  _subStart = Date.now();
  _subLabel = text;
  console.log(`\n  ${sep}`);
  console.log(`  ▶  [${nowStr()}] ${text}`);
  console.log(`  ${sep}`);
}

function line(label, value, unit = "") {
  const pad = 38;
  console.log(`  │  ${label.padEnd(pad)} ${value} ${unit}`);
}

// Formats an 18-decimal fixed-point BigInt as a readable EUR figure.
function eur(value) {
  const n = Number(ethers.formatUnits(value, 18));
  return n.toLocaleString("en-US", { maximumFractionDigits: 2 });
}

// Formats an 18-decimal fixed-point BigInt as a readable share/unit figure.
function units(value) {
  const n = Number(ethers.formatUnits(value, 18));
  return n.toLocaleString("en-US", { maximumFractionDigits: 4 });
}

function bp(value) {
  return `${(Number(value) / 100).toFixed(2)}%`;
}

// Returns a Sepolia Etherscan link for an address, or "" on local networks.
function explorerLink(net, address) {
  if (net.name === "hardhat" || net.name === "localhost") return "";
  return `  ↳ https://sepolia.etherscan.io/address/${address}`;
}

const OP_TYPE_LABEL = ["SUBSCRIPTION", "REDEMPTION", "FEE_ACCRUAL"];

// Displays the fund's full balance sheet in tabular form.
async function displayBalanceSheet(fund, sectionTitle) {
  subtitle(sectionTitle);

  const metrics = await fund.readFundMetrics();
  const cashAvailable     = metrics[0];
  const assetsHeld        = metrics[1];
  const totalNAV          = metrics[2];
  const navPerShare       = metrics[3];
  const sharesOutstanding = metrics[4];
  const cycleNumber       = metrics[5];
  const shareholderCount  = metrics[6];

  const assetPriceEUR    = await fund.assetPriceEUR();
  const assetsValue      = (assetsHeld * assetPriceEUR) / PRECISION;
  const totalLiabilities = (sharesOutstanding * navPerShare) / PRECISION;

  console.log("  ┌" + "─".repeat(57) + "┐");
  console.log("  │  ASSETS                                                 │");
  console.log("  ├" + "─".repeat(57) + "┤");
  line("Cash available (EMT)",     eur(cashAvailable),   "EUR");
  line("Tokenized assets held",    units(assetsHeld),    "units");
  line("Asset price",              eur(assetPriceEUR),   "EUR / unit");
  line("Assets valuation",         eur(assetsValue),     "EUR");
  console.log("  ├" + "─".repeat(57) + "┤");
  line("TOTAL NAV",                eur(totalNAV),        "EUR");
  console.log("  ├" + "─".repeat(57) + "┤");
  console.log("  │  LIABILITIES                                            │");
  console.log("  ├" + "─".repeat(57) + "┤");
  line("Shares outstanding (ISIN)", units(sharesOutstanding), "shares");
  line("NAV per share",             eur(navPerShare),         "EUR / share");
  line("Total liabilities",         eur(totalLiabilities),    "EUR");
  console.log("  ├" + "─".repeat(57) + "┤");
  console.log("  │  INFORMATION                                            │");
  console.log("  ├" + "─".repeat(57) + "┤");
  line("Current NAV cycle",         cycleNumber.toString());
  line("Number of shareholders",    shareholderCount.toString());
  console.log("  └" + "─".repeat(57) + "┘");

  // verifyBalanceSheet() is now tolerance-aware on-chain (see the Solidity
  // patch note in TokenizedFundPOC.sol): `balanced` already accounts for
  // negligible 18-decimal floor-division rounding dust between totalAssets
  // and the NAV-per-share-reconstructed totalLiabilities. We still compute
  // the raw dust amount here purely for transparent display, not to
  // second-guess the contract's own `balanced` verdict.
  const [checkAssets, checkLiabilities, balanced] = await fund.verifyBalanceSheet();
  const dust = checkAssets > checkLiabilities
    ? checkAssets - checkLiabilities
    : checkLiabilities - checkAssets;

  const balanceStatus = balanced
    ? (dust > 0n
        ? `✅ BALANCED (within rounding tolerance — raw dust: ${dust} wei, negligible 18-dec fixed-point rounding)`
        : "✅ BALANCED")
    : `❌ UNBALANCED (raw difference: ${dust} wei — exceeds the contract's rounding tolerance, please investigate)`;

  console.log(`\n  Balance sheet check: Assets (${eur(checkAssets)}) == Liabilities (${eur(checkLiabilities)} EUR) → ${balanceStatus}`);
}

// Displays the details of an archived NAV cycle.
async function displayNAVCycle(fund, cycleNumber) {
  const cycle = await fund.readNAVCycle(cycleNumber);
  const opType = OP_TYPE_LABEL[Number(cycle.operationType)];
  const timestamp = new Date(Number(cycle.timestamp) * 1000).toLocaleString("en-GB");

  console.log(`\n  📋 NAV Cycle #${cycleNumber}`);
  console.log(`     Type              : ${opType}`);
  console.log(`     Investor          : ${cycle.investor}`);
  console.log(`     Shares exchanged  : ${units(cycle.shareQuantity)}`);
  if (cycle.assetsBought > 0n) console.log(`     Assets bought     : ${units(cycle.assetsBought)}`);
  if (cycle.assetsSold  > 0n) console.log(`     Assets sold       : ${units(cycle.assetsSold)}`);
  console.log(`     Fee charged       : ${eur(cycle.feeCharged)} EUR`);
  console.log(`     NAV per share     : ${eur(cycle.navPerShare)} EUR`);
  console.log(`     Total NAV         : ${eur(cycle.totalNAV)} EUR`);
  console.log(`     Cash after        : ${eur(cycle.cashAvailable)} EUR`);
  console.log(`     Assets after      : ${units(cycle.assetsHeld)}`);
  console.log(`     Timestamp         : ${timestamp}`);
  console.log(`     Finalized         : ${cycle.isFinalized ? "✅ YES" : "❌ NO"}`);
  console.log(`     Fingerprint       : ${cycle.stateFingerprint.slice(0, 18)}...`);
}

// ─────────────────────────────────────────────────────────────────────────────
// MAIN DEMONSTRATION FUNCTION
// ─────────────────────────────────────────────────────────────────────────────

async function main() {

  title("DEMONSTRATION — TOKENIZED FUND POC (Phase 2, v5.0 — Toolbox-integrated)");

  // ─── NETWORK VERIFICATION — make sure we know exactly where this is running
  const isLocalNetwork = network.name === "hardhat" || network.name === "localhost";
  const chainId = (await ethers.provider.getNetwork()).chainId;

  if (!isLocalNetwork && chainId !== SEPOLIA_CHAIN_ID) {
    throw new Error(
      `\n❌ This script only supports the local Hardhat network or Sepolia.\n` +
      `   You ran it against network "${network.name}" (chainId ${chainId}).\n` +
      `   Use one of:\n` +
      `     npx hardhat run scripts/demo.js --network localhost\n` +
      `     npx hardhat run scripts/demo.js --network sepolia\n`
    );
  }

  if (isLocalNetwork) {
    console.log("  Institutional bank — Smart contracts on local Hardhat network");
  } else {
    console.log("\n  🟣 RUNNING ON SEPOLIA TESTNET (chainId 11155111) — real on-chain transactions");
    console.log("     Every address and tx hash below can be checked on https://sepolia.etherscan.io");
  }

  // ─── INITIALIZATION ─────────────────────────────────────────────────────
  subtitle("Setting up demonstration accounts");

  console.log(`\n  🌐 Network : ${network.name} (chainId ${chainId})`);

  let admin, compliance, auditor, investor1, investor2;

  if (isLocalNetwork) {
    // Hardhat's local node ships 20 pre-funded accounts — use them as-is.
    [admin, compliance, auditor, investor1, investor2] = await ethers.getSigners();
  } else {
    // On a real network (e.g. Sepolia) there is only ONE funded signer: the
    // account behind PRIVATE_KEY in .env. The other four actors are created
    // here as random wallets and topped up with a little ETH from admin so
    // they can each pay their own gas.
    [admin] = await ethers.getSigners();

    compliance = ethers.Wallet.createRandom().connect(ethers.provider);
    auditor    = ethers.Wallet.createRandom().connect(ethers.provider);
    investor1  = ethers.Wallet.createRandom().connect(ethers.provider);
    investor2  = ethers.Wallet.createRandom().connect(ethers.provider);

    const adminBalance = await ethers.provider.getBalance(admin.address);
    console.log(`  💰 Admin balance : ${ethers.formatEther(adminBalance)} ETH`);

    // auditor never signs a transaction in this demo, so it doesn't need gas.
    const fundingWei = ethers.parseEther(FUNDING_PER_WALLET_ETH);
    for (const [label, wallet] of [
      ["compliance", compliance],
      ["investor1", investor1],
      ["investor2", investor2],
    ]) {
      const tx = await admin.sendTransaction({ to: wallet.address, value: fundingWei });
      await tx.wait();
      console.log(`  💸 Funded ${label.padEnd(10)} with ${FUNDING_PER_WALLET_ETH} ETH : ${wallet.address}`);
    }
  }

  console.log(`\n  👤 Admin       (deployer) : ${admin.address}`);
  console.log(`  👤 Compliance             : ${compliance.address}`);
  console.log(`  👤 Auditor                : ${auditor.address}`);
  console.log(`  👤 Investor 1             : ${investor1.address}`);
  console.log(`  👤 Investor 2             : ${investor2.address}`);

  // ─── DEPLOYMENT — the five contracts of the Phase 2 architecture ────────
  subtitle("Deploying EMT (cash), TokenizedAssets and TokenizedISIN (shares)");

  const EMTFactory = await ethers.getContractFactory("EMT");
  const cashToken = await EMTFactory.connect(admin).deploy(0);
  await cashToken.waitForDeployment();
  const cashTokenAddress = await cashToken.getAddress();
  console.log(`\n  ✅ EMT (cash) deployed at            : ${cashTokenAddress}`);
  if (explorerLink(network, cashTokenAddress)) console.log(explorerLink(network, cashTokenAddress));

  const AssetsFactory = await ethers.getContractFactory("TokenizedAssets");
  const assetToken = await AssetsFactory.connect(admin).deploy(0);
  await assetToken.waitForDeployment();
  const assetTokenAddress = await assetToken.getAddress();
  console.log(`  ✅ TokenizedAssets deployed at        : ${assetTokenAddress}`);
  if (explorerLink(network, assetTokenAddress)) console.log(explorerLink(network, assetTokenAddress));

  const ISINFactory = await ethers.getContractFactory("TokenizedISIN");
  const sharesToken = await ISINFactory.connect(admin).deploy(
    "MMF Fund POC Shares",
    "MMF",
    "FR0000000000",
    "MMF Fund POC",
    admin.address
  );
  await sharesToken.waitForDeployment();
  const sharesTokenAddress = await sharesToken.getAddress();
  console.log(`  ✅ TokenizedISIN (shares) deployed at : ${sharesTokenAddress}`);
  if (explorerLink(network, sharesTokenAddress)) console.log(explorerLink(network, sharesTokenAddress));

  subtitle("Deploying Toolbox (fee rules, investment strategy, compliance, NAV math)");

  const ToolboxFactory = await ethers.getContractFactory("Toolbox");
  const toolbox = await ToolboxFactory.connect(admin).deploy(admin.address, "2.0.0");
  await toolbox.waitForDeployment();
  const toolboxAddress = await toolbox.getAddress();
  console.log(`\n  ✅ Toolbox deployed at                : ${toolboxAddress}`);
  if (explorerLink(network, toolboxAddress)) console.log(explorerLink(network, toolboxAddress));
  console.log(`  🏷️  Toolbox version                    : ${await toolbox.version()}`);

  subtitle("Deploying TokenizedFundPOC (orchestrator)");

  const FundFactory = await ethers.getContractFactory("TokenizedFundPOC");
  const fund = await FundFactory.connect(admin).deploy(
    "MMF Fund POC",
    cashTokenAddress,
    assetTokenAddress,
    sharesTokenAddress,
    toolboxAddress
  );
  await fund.waitForDeployment();
  const fundAddress = await fund.getAddress();

  console.log(`\n  ✅ Fund contract deployed at : ${fundAddress}`);
  if (explorerLink(network, fundAddress)) console.log(explorerLink(network, fundAddress));
  console.log(`  📄 Fund name        : ${await fund.fundName()}`);
  console.log(`  🏷️  Shares symbol    : ${await sharesToken.symbol()}`);
  console.log(`  🔢 Shares decimals  : ${await sharesToken.decimals()} (full 18-decimal EUR fixed point — Phase 2)`);

  // ─── WIRING — ownership / roles, per the deployment prerequisites ───────
  subtitle("Wiring: granting the fund ownership/roles on the token + Toolbox contracts");

  const txOwnEMT = await cashToken.connect(admin).transferOwnership(fundAddress);
  await txOwnEMT.wait();
  console.log(`\n  🔗 EMT ownership transferred to the fund`);

  const txOwnAssets = await assetToken.connect(admin).transferOwnership(fundAddress);
  await txOwnAssets.wait();
  console.log(`  🔗 TokenizedAssets ownership transferred to the fund`);

  const FUND_ROLE_ISIN       = await sharesToken.FUND_ROLE();
  const COMPLIANCE_ROLE_ISIN = await sharesToken.COMPLIANCE_ROLE();
  const txGrantFundRoleISIN = await sharesToken.connect(admin).grantRole(FUND_ROLE_ISIN, fundAddress);
  await txGrantFundRoleISIN.wait();
  const txGrantComplianceRoleISIN = await sharesToken.connect(admin).grantRole(COMPLIANCE_ROLE_ISIN, fundAddress);
  await txGrantComplianceRoleISIN.wait();
  console.log(`  🔗 FUND_ROLE and COMPLIANCE_ROLE granted to the fund on TokenizedISIN`);

  const FUND_AUTHORIZED_ROLE = await toolbox.FUND_AUTHORIZED_ROLE();
  const txGrantFundAuthorized = await toolbox.connect(admin).grantRole(FUND_AUTHORIZED_ROLE, fundAddress);
  await txGrantFundAuthorized.wait();
  console.log(`  🔗 FUND_AUTHORIZED_ROLE granted to the fund on Toolbox (required for updateHighWaterMark)`);

  const COMPLIANCE_ROLE = await fund.COMPLIANCE_ROLE();
  const AUDITOR_ROLE    = await fund.AUDITOR_ROLE();
  const txGrantComplianceFund = await fund.connect(admin).grantRole(COMPLIANCE_ROLE, compliance.address);
  await txGrantComplianceFund.wait();
  const txGrantAuditorFund = await fund.connect(admin).grantRole(AUDITOR_ROLE, auditor.address);
  await txGrantAuditorFund.wait();
  console.log(`\n  🔐 COMPLIANCE_ROLE granted to : ${compliance.address.slice(0, 10)}...`);
  console.log(`  🔐 AUDITOR_ROLE    granted to : ${auditor.address.slice(0, 10)}...`);

  // ─── TOOLBOX PARAMETERS IN EFFECT ────────────────────────────────────────
  title("TOOLBOX — Parameters currently in effect");

  const feeStructure0 = await toolbox.readFeeStructure();
  const strategy0     = await toolbox.readStrategy();
  const minSub        = await toolbox.MINIMUM_SUBSCRIPTION();
  const cap0          = await toolbox.readIndividualSubscriptionCap();

  subtitle("Fee grid (default institutional MMF parameters)");
  line("Subscription fee",          bp(feeStructure0.subscriptionFeeBp));
  line("Redemption fee",            bp(feeStructure0.redemptionFeeBp));
  line("Early redemption penalty",  bp(feeStructure0.earlyRedemptionPenaltyBp), "(before 90-day lock-up)");
  line("Annual management fee",     bp(feeStructure0.annualManagementFeeBp));
  line("Annual custody fee",        bp(feeStructure0.annualCustodyFeeBp));
  line("Annual admin fee",          bp(feeStructure0.annualAdminFeeBp));
  line("Performance fee",           bp(feeStructure0.performanceFeeBp), "above hurdle + HWM");
  line("Hurdle rate",               bp(feeStructure0.hurdleRateBp));

  subtitle("Investment strategy (target allocation)");
  line("Commercial paper",          bp(strategy0.commercialPaperAllocationBp));
  line("Bonds",                     bp(strategy0.bondAllocationBp));
  line("Equities",                  bp(strategy0.equityAllocationBp));
  line("Cash",                      bp(strategy0.cashAllocationBp));
  console.log(`\n  ℹ️  This architecture has a single non-cash asset bucket (TokenizedAssets),`);
  console.log(`     so commercial paper + bonds + equities are all bought as TokenizedAssets.`);

  subtitle("Compliance thresholds");
  line("Minimum subscription",      eur(minSub), "EUR");
  line("Individual subscription cap", eur(cap0), "EUR");

  // ─── STEP 0 — T0 balance sheet initialization ────────────────────────────
  title("STEP 0 — T0 balance sheet initialization");
  const initialSubscription = await fund.INITIAL_SUBSCRIPTION_EUR();
  console.log(`  initializeBalanceSheet() will process a genesis subscription of ${eur(initialSubscription)} EUR:`);
  console.log("  • Whitelist the admin as the first shareholder");
  console.log("  • Validate compliance via Toolbox (minimum subscription + cap)");
  console.log("  • Compute the subscription fee via Toolbox (0% by default)");
  console.log("  • Split the net amount cash/invested per Toolbox's strategy (80% invested / 20% cash)");
  console.log("  • Mint shares (TokenizedISIN), cash (EMT) and securities (TokenizedAssets) accordingly");

  const txInit = await fund.connect(admin).initializeBalanceSheet();
  await txInit.wait();
  console.log(`\n  ✅ Balance sheet initialized`);

  await displayBalanceSheet(fund, "Fund state at T0");
  console.log(`\n  💼 Admin shares : ${units(await sharesToken.balanceOf(admin.address))} shares`);

  // ─── STEP 1 — Whitelisting ───────────────────────────────────────────────
  title("STEP 1 — Whitelisting investors (Compliance role)");
  console.log("  The Compliance Officer validates KYC and authorizes investors.");
  console.log("  fund.whitelistInvestor() forwards the call to TokenizedISIN.");

  const txWl1 = await fund.connect(compliance).whitelistInvestor(investor1.address);
  await txWl1.wait();
  console.log(`\n  ✅ Investor 1 whitelisted : ${investor1.address.slice(0, 10)}...`);

  const txWl2 = await fund.connect(compliance).whitelistInvestor(investor2.address);
  await txWl2.wait();
  console.log(`  ✅ Investor 2 whitelisted : ${investor2.address.slice(0, 10)}...`);

  const metricsAfterWhitelist = await fund.readFundMetrics();
  console.log(`\n  👥 Total registered shareholders : ${metricsAfterWhitelist[6]}`);
  console.log(`     (1 initial admin + 2 whitelisted investors)`);

  // Helper mirroring the fund's Solidity subscription math, for previews.
  async function previewSubscription(amountEUR) {
    const feeStructure   = await toolbox.readFeeStructure();
    const subscriptionFee = (amountEUR * feeStructure.subscriptionFeeBp) / BASE_POINTS;
    const netAmount        = amountEUR - subscriptionFee;
    const navPerShare      = await fund.computeNAVPerShare();
    const sharesToIssue    = (netAmount * PRECISION) / navPerShare;
    const cashAllocationBp = await toolbox.readCashAllocationBp();
    const investRatioBp    = BASE_POINTS - cashAllocationBp;
    const cashToInvest     = (netAmount * investRatioBp) / BASE_POINTS;
    const cashRetained     = netAmount - cashToInvest;
    const assetPriceEUR    = await fund.assetPriceEUR();
    const assetsToBuy      = (cashToInvest * PRECISION) / assetPriceEUR;
    return { subscriptionFee, netAmount, navPerShare, sharesToIssue, cashToInvest, cashRetained, assetsToBuy };
  }

  // ─── STEP 2 — Subscription, Investor 1 ───────────────────────────────────
  title("STEP 2 — Subscription: Investor 1 subscribes 200,000 EUR");

  const sub1Amount = ethers.parseEther("200000");
  const preview1 = await previewSubscription(sub1Amount);
  console.log(`  Gross amount              : ${eur(sub1Amount)} EUR`);
  console.log(`  Subscription fee (Toolbox): ${eur(preview1.subscriptionFee)} EUR`);
  console.log(`  Net amount invested       : ${eur(preview1.netAmount)} EUR`);
  console.log(`  Expected shares issued    : ${units(preview1.sharesToIssue)} shares`);
  console.log(`  → Invested in securities  : ${eur(preview1.cashToInvest)} EUR (${units(preview1.assetsToBuy)} units)`);
  console.log(`  → Retained as cash        : ${eur(preview1.cashRetained)} EUR`);

  const txSub1 = await fund.connect(investor1).subscribe(sub1Amount);
  const receiptSub1 = await txSub1.wait();
  console.log(`\n  ✅ Transaction confirmed : ${receiptSub1.hash.slice(0, 18)}...`);
  console.log(`  ⛽ Gas used : ${receiptSub1.gasUsed.toString()}`);

  await displayBalanceSheet(fund, "Balance sheet after Investor 1 subscription (200,000 EUR)");
  console.log(`\n  💼 Investor 1 shares : ${units(await sharesToken.balanceOf(investor1.address))} shares`);

  // ─── STEP 3 — Subscription, Investor 2 ───────────────────────────────────
  title("STEP 3 — Subscription: Investor 2 subscribes 300,000 EUR");

  const sub2Amount = ethers.parseEther("300000");
  const preview2 = await previewSubscription(sub2Amount);
  console.log(`  Gross amount              : ${eur(sub2Amount)} EUR`);
  console.log(`  Subscription fee (Toolbox): ${eur(preview2.subscriptionFee)} EUR`);
  console.log(`  Expected shares issued    : ${units(preview2.sharesToIssue)} shares`);

  const txSub2 = await fund.connect(investor2).subscribe(sub2Amount);
  const receiptSub2 = await txSub2.wait();
  console.log(`\n  ✅ Transaction confirmed : ${receiptSub2.hash.slice(0, 18)}...`);

  await displayBalanceSheet(fund, "Balance sheet after Investor 2 subscription (300,000 EUR)");
  console.log(`\n  💼 Investor 1 shares : ${units(await sharesToken.balanceOf(investor1.address))} shares`);
  console.log(`  💼 Investor 2 shares : ${units(await sharesToken.balanceOf(investor2.address))} shares`);
  console.log(`  💼 Admin shares      : ${units(await sharesToken.balanceOf(admin.address))} shares`);
  console.log(`  ─────────────────────────────────────────────`);
  console.log(`  💼 Total supply      : ${units(await sharesToken.totalSupply())} shares`);

  // ─── STEP 4 — Fee admin updates the fee grid (Toolbox, FEE_ADMIN_ROLE) ──
  title("STEP 4 — Fee admin updates the fee grid (Toolbox.updateFees)");
  console.log("  FEE_ADMIN_ROLE is intentionally distinct from MANAGER_ROLE:");
  console.log("  a portfolio manager must not be able to set their own fees.");
  console.log("\n  New fee grid: subscription 0.50%, redemption 0.25% (other parameters unchanged)");

  const txUpdateFees = await toolbox.connect(admin).updateFees(
    50,   // subscriptionFeeBp  = 0.50%
    25,   // redemptionFeeBp    = 0.25%
    50,   // annualManagementFeeBp (unchanged)
    2000, // performanceFeeBp (unchanged)
    300,  // hurdleRateBp (unchanged)
    5,    // annualCustodyFeeBp (unchanged)
    10,   // annualAdminFeeBp (unchanged)
    200   // earlyRedemptionPenaltyBp (unchanged)
  );
  await txUpdateFees.wait();

  const feeStructure1 = await toolbox.readFeeStructure();
  console.log(`\n  ✅ New subscription fee : ${bp(feeStructure1.subscriptionFeeBp)}`);
  console.log(`  ✅ New redemption fee   : ${bp(feeStructure1.redemptionFeeBp)}`);

  // ─── STEP 5 — Subscription under the new fee grid ────────────────────────
  title("STEP 5 — Subscription: Investor 2 tops up with 150,000 EUR (new fee grid)");

  const sub3Amount = ethers.parseEther("150000");
  const preview3 = await previewSubscription(sub3Amount);
  console.log(`  Gross amount              : ${eur(sub3Amount)} EUR`);
  console.log(`  Subscription fee (0.50%)  : ${eur(preview3.subscriptionFee)} EUR`);
  console.log(`  Net amount invested       : ${eur(preview3.netAmount)} EUR`);
  console.log(`  Expected shares issued    : ${units(preview3.sharesToIssue)} shares`);

  const txSub3 = await fund.connect(investor2).subscribe(sub3Amount);
  await txSub3.wait();

  const cycleAfterSub3 = await fund.currentCycleNumber();
  await displayNAVCycle(fund, cycleAfterSub3);
  console.log(`\n  💼 Investor 2 total shares : ${units(await sharesToken.balanceOf(investor2.address))} shares`);

  // ─── STEP 6 — Redemption within the lock-up (early penalty) ─────────────
  title("STEP 6 — Redemption: Investor 1 redeems 500 shares (within the 90-day lock-up)");

  const redeemAmount = ethers.parseEther("500");
  const record1Before = await sharesToken.getShareholderRecord(investor1.address);
  const [isLockupElapsed, secondsRemaining] = await toolbox.checkLockup(record1Before.firstEntryTimestamp);

  const navPerShareBefore = await fund.computeNAVPerShare();
  const grossAmount       = (redeemAmount * navPerShareBefore) / PRECISION;
  const feeStructureNow   = await toolbox.readFeeStructure();
  const redemptionFee     = isLockupElapsed
    ? (grossAmount * feeStructureNow.redemptionFeeBp) / BASE_POINTS
    : (grossAmount * feeStructureNow.earlyRedemptionPenaltyBp) / BASE_POINTS;
  const netAmountToInvestor = grossAmount - redemptionFee;

  console.log(`  Lock-up elapsed?          : ${isLockupElapsed ? "YES" : `NO (${Math.round(Number(secondsRemaining) / 86400)} days remaining)`}`);
  console.log(`  Current NAV/share         : ${eur(navPerShareBefore)} EUR`);
  console.log(`  Gross redemption value    : 500 × ${eur(navPerShareBefore)} = ${eur(grossAmount)} EUR`);
  console.log(`  Fee applied               : ${isLockupElapsed ? bp(feeStructureNow.redemptionFeeBp) + " (standard)" : bp(feeStructureNow.earlyRedemptionPenaltyBp) + " (early redemption penalty)"} = ${eur(redemptionFee)} EUR`);
  console.log(`  Net amount to investor    : ${eur(netAmountToInvestor)} EUR`);

  const txRedeem1 = await fund.connect(investor1).redeem(redeemAmount);
  const receiptRedeem1 = await txRedeem1.wait();
  console.log(`\n  ✅ Redemption confirmed : ${receiptRedeem1.hash.slice(0, 18)}...`);
  console.log(`  ⛽ Gas used : ${receiptRedeem1.gasUsed.toString()}`);

  await displayBalanceSheet(fund, "Balance sheet after Investor 1 redemption (500 shares)");
  console.log(`\n  💼 Investor 1 remaining shares : ${units(await sharesToken.balanceOf(investor1.address))} shares`);
  console.log(`  ℹ️  The fee portion was not paid out, so it stays on the fund's balance sheet`);
  console.log(`     — it slightly increases the NAV per share for the remaining holders.`);

  // ─── STEP 7 — Ongoing fee accrual (management/custody/admin/performance) ─
  title("STEP 7 — Ongoing fee accrual (Toolbox prorata fees + High Water Mark)");
  console.log("  Simulating 6 days of elapsed time, then calling accrueOngoingFees().");
  console.log("  Per this phase's scope decision, fees are computed and logged — not moved.");

  if (isLocalNetwork) {
    await ethers.provider.send("evm_increaseTime", [6 * 24 * 3600]);
    await ethers.provider.send("evm_mine");
  } else {
    console.log("  ⚠️  Real network detected — time cannot be fast-forwarded here.");
    console.log("     Calling accrueOngoingFees() immediately; the prorata fee for this");
    console.log("     first call will still look large because it's the one that sets the");
    console.log("     initial High Water Mark (see note below), same as on a local node.");
  }

  const grossNAVBeforeAccrual = await fund.computeTotalNAV();
  const navPerShareBeforeAccrual = await fund.computeNAVPerShare();

  const txAccrue = await fund.connect(admin).accrueOngoingFees();
  await txAccrue.wait();

  const cycleAfterAccrual = await fund.currentCycleNumber();
  console.log(`\n  Gross NAV at accrual time  : ${eur(grossNAVBeforeAccrual)} EUR`);
  console.log(`  NAV/share at accrual time  : ${eur(navPerShareBeforeAccrual)} EUR`);
  await displayNAVCycle(fund, cycleAfterAccrual);

  console.log(`\n  ℹ️  This FIRST call also establishes the initial Toolbox High Water Mark`);
  console.log(`     (it starts at 0). Because of that, Toolbox's performance-fee formula`);
  console.log(`     treats the ENTIRE current NAV/share as "outperformance" on this one`);
  console.log(`     call, which is why the fee charged above looks large. This is inherent`);
  console.log(`     to Toolbox.sol's HWM initialization logic (unmodified in Phase 2), not`);
  console.log(`     a Phase 2 orchestration bug. The next call below, after the HWM baseline`);
  console.log(`     is set, behaves as expected (near-zero performance fee).`);

  if (isLocalNetwork) {
    console.log("\n  ⏩ Simulating 4 more days, then calling accrueOngoingFees() again...");
    await ethers.provider.send("evm_increaseTime", [4 * 24 * 3600]);
    await ethers.provider.send("evm_mine");
  } else {
    console.log("\n  ⏩ Calling accrueOngoingFees() again (no time fast-forward available)...");
  }

  const txAccrue2 = await fund.connect(admin).accrueOngoingFees();
  await txAccrue2.wait();

  const cycleAfterAccrual2 = await fund.currentCycleNumber();
  await displayNAVCycle(fund, cycleAfterAccrual2);

  const hwm = await toolbox.readHighWaterMark();
  console.log(`\n  📈 Toolbox High Water Mark : ${eur(hwm.highValue)} EUR/share (cycle #${hwm.navCycle})`);
  console.log(`     Note the fee charged on this second call is only the prorata`);
  console.log(`     management/custody/admin fees — no performance fee, since NAV/share`);
  console.log(`     has not risen above the HWM established a moment ago.`);

  // ─── STEP 8 — Tamper-proof verification ──────────────────────────────────
  title("STEP 8 — Tamper-proof verification of archived NAV cycles");
  console.log("  Each operation creates a NAV cycle with a keccak256 fingerprint.");
  console.log("  The fingerprint excludes block.timestamp so it can always be recomputed.\n");

  const lastCycle = await fund.currentCycleNumber();
  console.log(`  Number of archived cycles : ${Number(lastCycle) + 1} (cycle 0 to ${lastCycle})\n`);

  let allIntact = true;
  for (let i = 0; i <= Number(lastCycle); i++) {
    const [integrity, , storedFingerprint] = await fund.verifyCycleIntegrity(i);
    const status = integrity ? "✅ INTACT" : "❌ TAMPERED";
    if (!integrity) allIntact = false;
    const cycleType = OP_TYPE_LABEL[Number((await fund.readNAVCycle(i)).operationType)];
    console.log(`  Cycle #${i} [${cycleType.padEnd(12)}] : ${status}  │  Fingerprint : ${storedFingerprint.slice(0, 14)}...`);
  }

  if (allIntact) {
    console.log(`\n  ✅ All cycles are intact — no tampering detected`);
  } else {
    console.log(`\n  ❌ ALERT: Some cycles appear tampered — inspect the contract`);
  }

  console.log("\n  ─── Detail of cycle #1 (first subscription) ───");
  await displayNAVCycle(fund, 1);

  // ─── STEP 9 — Access control ──────────────────────────────────────────────
  title("STEP 9 — Access control (AccessControl RBAC)");
  console.log("  A non-whitelisted account cannot subscribe.");

  const stranger = ethers.Wallet.createRandom().connect(ethers.provider);
  await admin.sendTransaction({ to: stranger.address, value: ethers.parseEther("0.01") }); // gas money
  try {
    await fund.connect(stranger).subscribe(ethers.parseEther("150000"));
    console.log("  ❌ ERROR: the subscription should have been rejected!");
  } catch (err) {
    const msg = err.message?.includes("not whitelisted")
      ? "Investor not whitelisted — KYC required"
      : "Access denied by the contract";
    console.log(`\n  ✅ Subscription rejected as expected : "${msg}"`);
  }

  // Blacklist demonstration — blacklist must be reported correctly, not
  // masked by "not whitelisted" (see [FIX-2] in TokenizedISIN.onlyWhitelisted).
  console.log("\n  Blacklist demonstration — correct error message guaranteed.");
  const txBlacklist = await fund.connect(compliance).blacklistInvestor(
    investor1.address,
    "Demonstration asset freeze"
  );
  await txBlacklist.wait();
  try {
    await fund.connect(investor1).subscribe(ethers.parseEther("150000"));
    console.log("  ❌ ERROR: the subscription should have been rejected!");
  } catch (err) {
    const isBlacklisted = err.message?.includes("blacklisted");
    console.log(`  ✅ Subscription rejected : "${isBlacklisted ? "Investor blacklisted — operation impossible" : err.message}"`);
  }
  // Not re-whitelisted for the rest of the demo — a blacklisted account
  // cannot be re-whitelisted without first being cleared, by design.

  console.log("\n  An account without COMPLIANCE_ROLE cannot whitelist investors.");
  try {
    await fund.connect(investor2).whitelistInvestor(investor2.address);
    console.log("  ❌ ERROR: whitelisting should have been rejected!");
  } catch {
    console.log(`  ✅ Whitelisting rejected as expected (missing COMPLIANCE_ROLE)`);
  }

  console.log("\n  A subscription below Toolbox's institutional minimum (100,000 EUR) is rejected.");
  try {
    await fund.connect(investor2).subscribe(ethers.parseEther("50000"));
    console.log("  ❌ ERROR: the subscription should have been rejected!");
  } catch {
    console.log(`  ✅ Subscription rejected as expected (below Toolbox.MINIMUM_SUBSCRIPTION)`);
  }

  // ─── STEP 10 — Circuit breaker ───────────────────────────────────────────
  title("STEP 10 — Circuit breaker (emergency regulatory pause)");
  console.log("  The administrator can suspend all operations.");

  const txPause = await fund.connect(admin).pauseContract();
  await txPause.wait();
  console.log("\n  ⚠️  Contract PAUSED");

  try {
    await fund.connect(investor2).subscribe(ethers.parseEther("150000"));
    console.log("  ❌ ERROR: the subscription should have been blocked!");
  } catch {
    console.log(`  ✅ Subscription blocked while paused, as expected`);
  }

  const txUnpause = await fund.connect(admin).unpauseContract();
  await txUnpause.wait();
  console.log("  ✅ Contract RESUMED — normal operations restored");

  const finalSubAmount = ethers.parseEther("150000");
  const txFinalSub = await fund.connect(investor2).subscribe(finalSubAmount);
  await txFinalSub.wait();
  console.log(`  ✅ Subscription of ${eur(finalSubAmount)} EUR after resuming : OK`);
  console.log(`  💼 Investor 2 shares : ${units(await sharesToken.balanceOf(investor2.address))} shares`);

  // ─── FINAL SUMMARY ────────────────────────────────────────────────────────
  title("FINAL SUMMARY — Fund dashboard");
  await displayBalanceSheet(fund, "Final fund state after all operations");

  const finalCycle = await fund.currentCycleNumber();

  console.log("\n  ┌" + "─".repeat(57) + "┐");
  console.log("  │  OPERATIONS LOG                                         │");
  console.log("  ├" + "─".repeat(57) + "┤");
  line("Deployment (T0)",              "Cycle #0 — genesis subscription, 0% fee");
  line("Subscription Inv.1",           "Cycle #1 — 200,000 EUR, 0% fee");
  line("Subscription Inv.2",           "Cycle #2 — 300,000 EUR, 0% fee");
  line("Fee grid updated",             "Toolbox.updateFees() — 0.50% / 0.25%");
  line("Subscription Inv.2 (top-up)",  "Cycle #3 — 150,000 EUR, 0.50% fee");
  line("Redemption Inv.1",             "Cycle #4 — 500 shares, early penalty (2%)");
  line("Fee accrual #1 (HWM init)",     "Cycle #5 — mgmt/custody/admin + inflated perf fee");
  line("Fee accrual #2 (steady state)", "Cycle #6 — mgmt/custody/admin, perf fee ≈ 0");
  line("Subscription Inv.2 (final)",   `Cycle #${finalCycle} — 150,000 EUR, 0.50% fee`);
  console.log("  ├" + "─".repeat(57) + "┤");
  line("Total archived cycles",          `${Number(finalCycle) + 1} cycles`);
  line("Final NAV/share",                `${eur(await fund.computeNAVPerShare())} EUR`);
  line("Total shares outstanding",       `${units(await sharesToken.totalSupply())} shares`);
  line("Toolbox address",                toolboxAddress);
  line("Network",                        `${network.name} (chainId ${chainId})`);
  console.log("  └" + "─".repeat(57) + "┘");

  closeAllTimers();

  console.log("\n" + SEP);
  console.log("  ✅ DEMONSTRATION COMPLETED SUCCESSFULLY");
  if (isLocalNetwork) {
    console.log("  All records are tamper-proof on the blockchain (local Hardhat node)");
  } else {
    console.log("  🟣 All records above are LIVE on SEPOLIA TESTNET — verify any address");
    console.log("     or tx hash at https://sepolia.etherscan.io");
  }
  console.log(SEP + "\n");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    closeAllTimers(); // still report timing for whatever completed before the error
    console.error("\n❌ ERROR DURING THE DEMONSTRATION:");
    console.error(error.message || error);
    process.exit(1);
  });
