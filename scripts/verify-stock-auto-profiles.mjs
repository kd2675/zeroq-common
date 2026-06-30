#!/usr/bin/env node
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

const root = new URL("..", import.meta.url).pathname;
const batchProfileBehaviorTexts = readProfileBehaviorTexts();
const batchPolicyText = batchProfileBehaviorTexts.map((source) => source.text).join("\n");
const backMarketText = read("stock-back-service/src/main/java/stock/back/service/market/biz/MarketService.java");
const batchRuntimeTestText = [
  read("stock-batch-service/src/test/java/stock/batch/service/automarket/biz/AutoMarketServiceTest.java"),
  read("stock-batch-service/src/test/java/stock/batch/service/automarket/biz/AutoParticipantCashFlowServiceTest.java"),
].join("\n");

const sources = {
  batchEnum: parseJavaEnum(read("stock-batch-service/src/main/java/stock/batch/service/batch/automarket/model/AutoParticipantProfileType.java")),
  backEnum: parseJavaEnum(read("stock-back-service/src/main/java/stock/back/service/database/entity/AutoParticipantProfileType.java")),
  frontType: parseTypeUnion(read("stock-front-service/app/types/stock.ts"), "AutoParticipantProfileType"),
  frontOptions: parseFrontOptions(read("stock-front-service/app/lib/autoParticipantProfiles.ts")),
  frontBehaviorDescriptions: parseFrontBehaviorDescriptions(read("stock-front-service/app/lib/autoParticipantProfiles.ts")),
  batchBehaviorClasses: parseBehaviorClasses(batchProfileBehaviorTexts),
  batchPolicies: parseBatchPolicyProfiles(batchPolicyText),
  backDefaults: parseMapPuts(backMarketText, "defaults"),
  batchMysqlParticipantDdl: parseDdlConstraintProfiles(read("stock-batch-service/src/main/resources/db/ddl/stock_all.sql"), "chk_stock_auto_participant_profile_type"),
  batchMysqlConfigDdl: parseDdlConstraintProfiles(read("stock-batch-service/src/main/resources/db/ddl/stock_all.sql"), "chk_stock_auto_profile_config_type"),
  batchH2ParticipantDdl: parseDdlConstraintProfiles(read("stock-batch-service/src/main/resources/db/ddl/stock_h2.sql"), "chk_stock_auto_participant_profile_type"),
  batchH2ConfigDdl: parseDdlConstraintProfiles(read("stock-batch-service/src/main/resources/db/ddl/stock_h2.sql"), "chk_stock_auto_profile_config_type"),
  backMysqlParticipantDdl: parseDdlConstraintProfiles(read("stock-back-service/src/main/resources/db/ddl/stock_all.sql"), "chk_stock_auto_participant_profile_type"),
  backMysqlConfigDdl: parseDdlConstraintProfiles(read("stock-back-service/src/main/resources/db/ddl/stock_all.sql"), "chk_stock_auto_profile_config_type"),
  autoMarketSpec: parseMarkdownProfileTable(read("stock-back-service/docs/market-simulation/development-specs/06-auto-market.md")),
  batchRuntimeTests: parseRuntimeTestProfiles(batchRuntimeTestText),
};

const canonical = sources.batchEnum;
const checks = Object.entries(sources).map(([name, profiles]) => [
  name,
  sameSet(canonical, profiles),
  diff(canonical, profiles),
]);

for (const [name, ok, detail] of checks) {
  console.log(`${ok ? "PASS" : "FAIL"} ${name} matches batch enum${formatDiff(detail)}`);
}

const failed = checks.filter(([, ok]) => !ok);
if (failed.length) {
  console.error(`stock auto profile contract failed: ${failed.length} source(s) out of sync`);
  process.exit(1);
}

const profileDefaultMismatches = compareProfileConfigDefaults(
  parseBatchProfileConfigDefaults(batchPolicyText),
  parseBackProfileConfigDefaults(backMarketText),
  canonical,
);
if (profileDefaultMismatches.length) {
  console.log(`FAIL profileConfigDefaults match batch policy (${profileDefaultMismatches.join("; ")})`);
  console.error("stock auto profile contract failed: profile config defaults are out of sync");
  process.exit(1);
}
console.log("PASS profileConfigDefaults match batch policy");

const missingBehaviorMarkers = profileBehaviorMarkerMismatches(batchRuntimeTestText, canonical);
if (missingBehaviorMarkers.length) {
  console.log(`FAIL profileBehaviorTests cover profile behavior (${missingBehaviorMarkers.join("; ")})`);
  console.error("stock auto profile contract failed: profile behavior tests are incomplete");
  process.exit(1);
}
console.log("PASS profileBehaviorTests cover profile behavior");
console.log(`stock auto profile contract passed: ${canonical.length} profiles`);

function read(relativePath) {
  return readFileSync(join(root, relativePath), "utf8");
}

function readProfileBehaviorTexts() {
  const profileDir = "stock-batch-service/src/main/java/stock/batch/service/automarket/profile";
  return readdirSync(join(root, profileDir))
    .filter((fileName) => fileName.endsWith("Behavior.java") && fileName !== "AutoProfileBehavior.java" && fileName !== "AbstractAutoProfileBehavior.java")
    .sort()
    .map((fileName) => ({
      fileName,
      text: read(`${profileDir}/${fileName}`),
    }));
}

function parseJavaEnum(text) {
  const match = text.match(/public enum AutoParticipantProfileType\s*\{([\s\S]*?);/);
  if (!match) {
    throw new Error("AutoParticipantProfileType enum body not found");
  }
  return match[1]
    .split(",")
    .map((value) => value.trim())
    .filter(Boolean);
}

function parseTypeUnion(text, typeName) {
  const match = text.match(new RegExp(`export type ${typeName} =([\\s\\S]*?);`));
  if (!match) {
    throw new Error(`${typeName} union not found`);
  }
  return [...match[1].matchAll(/"([A-Z_]+)"/g)].map((matchItem) => matchItem[1]);
}

function parseFrontOptions(text) {
  return [...text.matchAll(/value:\s*"([A-Z_]+)"/g)].map((matchItem) => matchItem[1]);
}

function parseFrontBehaviorDescriptions(text) {
  return [...text.matchAll(/\{\s*value:\s*"([A-Z_]+)"[\s\S]*?behavior:\s*"[^"]+"/g)]
    .map((matchItem) => matchItem[1])
    .filter((value, index, values) => values.indexOf(value) === index);
}

function parseMapPuts(text, mapName) {
  const escapedMapName = mapName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return [...text.matchAll(new RegExp(`${escapedMapName}\\.put\\(AutoParticipantProfileType\\.([A-Z_]+)`, "g"))]
    .map((matchItem) => matchItem[1])
    .filter((value, index, values) => values.indexOf(value) === index);
}

function parseBehaviorClasses(sources) {
  return sources
    .map((source) => {
      const classMatch = source.text.match(/public class \w+Behavior extends AbstractAutoProfileBehavior/);
      const typeMatch = source.text.match(/super\(AutoParticipantProfileType\.([A-Z_]+),/);
      if (!classMatch || !typeMatch) {
        throw new Error(`profile behavior contract not found: ${source.fileName}`);
      }
      return typeMatch[1];
    })
    .filter((value, index, values) => values.indexOf(value) === index);
}

function parseBatchPolicyProfiles(text) {
  return [...text.matchAll(/super\(AutoParticipantProfileType\.([A-Z_]+),\s*new ProfilePolicy\(/g)]
    .map((matchItem) => matchItem[1])
    .filter((value, index, values) => values.indexOf(value) === index);
}

function parseBatchProfileConfigDefaults(text) {
  const defaults = new Map();
  for (const match of text.matchAll(/super\(AutoParticipantProfileType\.([A-Z_]+),\s*new ProfilePolicy\(([\s\S]*?)\)\);/g)) {
    const args = splitArguments(match[2]);
    defaults.set(match[1], {
      newsWeight: parseJavaValue(args[0], text),
      momentumWeight: parseJavaValue(args[1], text),
      contrarianWeight: parseJavaValue(args[2], text),
      lossAversionWeight: parseJavaValue(args[3], text),
      herdingWeight: parseJavaValue(args[4], text),
      marketMakingWeight: parseJavaValue(args[5], text),
      overconfidenceWeight: parseJavaValue(args[6], text),
      profitTakingWeight: parseJavaValue(args[7], text),
      orderMultiplier: parseJavaValue(args[8], text),
      aggressionMultiplier: parseJavaValue(args[9], text),
      orderTtlMultiplier: parseJavaValue(args[10], text),
      noiseWeight: parseJavaValue(args[11], text),
      quantityMultiplier: parseJavaValue(args[12], text),
      panicSellWeight: parseJavaValue(args[13], text),
      dipBuyWeight: parseJavaValue(args[14], text),
      holdingPatienceWeight: parseJavaValue(args[15], text),
      deepLossHoldWeight: parseJavaValue(args[16], text),
      recurringDepositAmount: parseJavaValue(args[17], text),
      recurringDepositIntervalValue: parseJavaValue(args[18], text),
      recurringDepositIntervalUnit: "DAY",
    });
  }
  return defaults;
}

function parseBackProfileConfigDefaults(text) {
  const defaults = new Map();
  for (const line of text.split("\n")) {
    const match = line.match(/defaults\.put\(AutoParticipantProfileType\.([A-Z_]+), profileDefaults\((.*)\)\);/);
    if (!match) {
      continue;
    }
    const args = splitArguments(match[2]);
    defaults.set(match[1], {
      newsWeight: parseJavaValue(args[0], text),
      momentumWeight: parseJavaValue(args[1], text),
      contrarianWeight: parseJavaValue(args[2], text),
      lossAversionWeight: parseJavaValue(args[3], text),
      herdingWeight: parseJavaValue(args[4], text),
      marketMakingWeight: parseJavaValue(args[5], text),
      overconfidenceWeight: parseJavaValue(args[6], text),
      noiseWeight: parseJavaValue(args[7], text),
      panicSellWeight: parseJavaValue(args[8], text),
      dipBuyWeight: parseJavaValue(args[9], text),
      orderMultiplier: parseJavaValue(args[10], text),
      aggressionMultiplier: parseJavaValue(args[11], text),
      orderTtlMultiplier: parseJavaValue(args[12], text),
      quantityMultiplier: parseJavaValue(args[13], text),
      holdingPatienceWeight: parseJavaValue(args[14], text),
      deepLossHoldWeight: parseJavaValue(args[15], text),
      profitTakingWeight: parseJavaValue(args[16], text),
      recurringDepositAmount: parseJavaValue(args[17], text),
      recurringDepositIntervalValue: args[18] == null ? parseJavaValue("DEFAULT_RECURRING_DEPOSIT_INTERVAL_DAYS", text) : parseJavaValue(args[18], text),
      recurringDepositIntervalUnit: args[19] == null ? "DAY" : parseJavaUnitValue(args[19]),
    });
  }
  return defaults;
}

function compareProfileConfigDefaults(batchDefaults, backDefaults, profiles) {
  const fields = [
    "newsWeight",
    "momentumWeight",
    "contrarianWeight",
    "lossAversionWeight",
    "herdingWeight",
    "marketMakingWeight",
    "overconfidenceWeight",
    "noiseWeight",
    "panicSellWeight",
    "dipBuyWeight",
    "orderMultiplier",
    "aggressionMultiplier",
    "orderTtlMultiplier",
    "quantityMultiplier",
    "holdingPatienceWeight",
    "deepLossHoldWeight",
    "profitTakingWeight",
    "recurringDepositAmount",
    "recurringDepositIntervalValue",
    "recurringDepositIntervalUnit",
  ];
  const mismatches = [];
  for (const profile of profiles) {
    const batchDefault = batchDefaults.get(profile);
    const backDefault = backDefaults.get(profile);
    if (!batchDefault || !backDefault) {
      mismatches.push(`${profile}: missing defaults`);
      continue;
    }
    for (const field of fields) {
      if (field === "recurringDepositIntervalUnit") {
        if (batchDefault[field] !== backDefault[field]) {
          mismatches.push(`${profile}.${field}: batch=${batchDefault[field]} back=${backDefault[field]}`);
        }
        continue;
      }
      if (!sameNumber(batchDefault[field], backDefault[field])) {
        mismatches.push(`${profile}.${field}: batch=${batchDefault[field]} back=${backDefault[field]}`);
      }
    }
  }
  return mismatches;
}

function splitArguments(text) {
  const args = [];
  let current = "";
  let depth = 0;
  let quote = null;
  for (const char of text) {
    if (quote) {
      current += char;
      if (char === quote) {
        quote = null;
      }
      continue;
    }
    if (char === "\"" || char === "'") {
      quote = char;
      current += char;
      continue;
    }
    if (char === "(") {
      depth++;
      current += char;
      continue;
    }
    if (char === ")") {
      depth--;
      current += char;
      continue;
    }
    if (char === "," && depth === 0) {
      args.push(current.trim());
      current = "";
      continue;
    }
    current += char;
  }
  if (current.trim()) {
    args.push(current.trim());
  }
  return args;
}

function parseJavaValue(value, sourceText) {
  const trimmed = value.trim();
  if (trimmed === "BigDecimal.ZERO") {
    return 0;
  }
  if (trimmed === "DEFAULT_RECURRING_DEPOSIT_INTERVAL_DAYS") {
    const match = sourceText.match(/DEFAULT_RECURRING_DEPOSIT_INTERVAL_DAYS\s*=\s*(\d+)/);
    if (!match) {
      throw new Error("DEFAULT_RECURRING_DEPOSIT_INTERVAL_DAYS not found");
    }
    return Number(match[1]);
  }
  const bigDecimalMatch = trimmed.match(/new BigDecimal\("([0-9.]+)"\)/);
  if (bigDecimalMatch) {
    return Number(bigDecimalMatch[1]);
  }
  const stringNumberMatch = trimmed.match(/^"([0-9.]+)"$/);
  if (stringNumberMatch) {
    return Number(stringNumberMatch[1]);
  }
  return Number(trimmed);
}

function parseJavaUnitValue(value) {
  const trimmed = value.trim();
  const enumMatch = trimmed.match(/RecurringCashIntervalUnit\.([A-Z_]+)/);
  if (enumMatch) {
    return enumMatch[1];
  }
  const stringMatch = trimmed.match(/^"([A-Z_]+)"$/);
  return stringMatch ? stringMatch[1] : trimmed;
}

function sameNumber(left, right) {
  return Math.abs(left - right) < 0.0000001;
}

function parseDdlConstraintProfiles(text, constraintName) {
  const escapedConstraintName = constraintName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = text.match(new RegExp(`CONSTRAINT ${escapedConstraintName} CHECK \\(([\\s\\S]*?)\\n\\s*\\)`, "m"));
  if (!match) {
    throw new Error(`${constraintName} constraint not found`);
  }
  return [...match[1].matchAll(/WHEN '([A-Z_]+)' THEN 1/g)]
    .map((matchItem) => matchItem[1])
    .filter((value, index, values) => values.indexOf(value) === index);
}

function parseMarkdownProfileTable(text) {
  const section = text.match(/## 자동 참여자 프로필([\s\S]*?)\n## /);
  if (!section) {
    throw new Error("auto participant profile section not found");
  }
  return [...section[1].matchAll(/\| `([A-Z_]+)` \|/g)].map((matchItem) => matchItem[1]);
}

function parseRuntimeTestProfiles(text) {
  const markerMap = profileBehaviorMarkers();
  return Object.entries(markerMap)
    .filter(([, markers]) => markers.every((marker) => marker.test(text)))
    .map(([profile]) => profile)
    .filter((profile, index, profiles) => profiles.indexOf(profile) === index);
}

function profileBehaviorMarkers() {
  return {
    NEWS_REACTIVE: [
      /effectiveIntensity_newsReactiveProfile_respondsMoreStronglyToReportScore/,
      /runAutoMarketStep_newsReactiveBuysOnStrongPositiveReport/,
      /runAutoMarketStep_newsReactiveSellsOnStrongNegativeReport/,
    ],
    MOMENTUM_FOLLOWER: [
      /buyBias_momentumFollowerAndContrarian_moveOppositeOnRisingPrice/,
      /runAutoMarketStep_momentumFollowerBuysAfterSharpRise/,
      /runAutoMarketStep_momentumFollowerSellsAfterSharpDrop/,
    ],
    CONTRARIAN: [
      /buyBias_momentumFollowerAndContrarian_moveOppositeOnRisingPrice/,
      /runAutoMarketStep_contrarianBuysAfterSharpDrop/,
    ],
    LOSS_AVERSE: [
      /buyBias_lossAverseProfile_prefersHoldingOrBuyingWhenPositionIsLosing/,
      /runAutoMarketStep_lossAverseLosingPositionAndNoCashDoesNotForceSell/,
    ],
    OVERCONFIDENT: [
      /buyBias_overconfidentProfileKeepsBuyingBiasAfterWinningPosition/,
      /orderCount_overconfidentProfile_increasesAfterWinningPosition/,
      /runAutoMarketStep_overconfidentProfilePlacesMoreOrdersAfterLargeGain/,
    ],
    HERD_FOLLOWER: [
      /buyBias_herdFollowerFollowsBuyCrowdAndMarketMakerLeansAgainstIt/,
      /runAutoMarketStep_herdFollowerBuysWhenOpenBuyOrdersDominate/,
      /runAutoMarketStep_herdFollowerSellsWhenOpenSellOrdersDominate/,
    ],
    MARKET_MAKER: [
      /buyBias_herdFollowerFollowsBuyCrowdAndMarketMakerLeansAgainstIt/,
      /runAutoMarketStep_marketMakerPlacesTwoSidedQuotesWhenCashAndInventoryExist/,
    ],
    NOISE_TRADER: [
      /buyBias_paydayAccumulatorKeepsHigherBuyBiasThanNoiseTraderOnNeutralSignal/,
      /runAutoMarketStep_noiseTraderWithoutCashOrHoldingCannotCreateOrder/,
    ],
    VALUE_ANCHOR: [
      /buyBias_valueAnchorBuysMoreBelowReferenceAndLessAboveReference/,
      /runAutoMarketStep_valueAnchorSellsAfterSharpRise/,
      /runAutoMarketStep_valueAnchorBuysAfterSharpDrop/,
    ],
    SCALPER: [
      /buyBias_scalperTakesProfitMoreThanLongTermHolderOnWinningPosition/,
      /runAutoMarketStep_shortTermProfilesTakeProfitBeforeHighIntensityBuy/,
      /orderTtl_scalperExpiresFasterThanLongTermHolder/,
    ],
    DAY_TRADER: [
      /orderCount_dayTraderTradesMoreOftenThanScalperOnNeutralSignal/,
      /runAutoMarketStep_dayTraderTradesMoreOftenThanLongTermHolderAtStrongSignal/,
      /runAutoMarketStep_shortTermProfilesTakeProfitBeforeHighIntensityBuy/,
    ],
    SWING_TRADER: [
      /buyBias_swingTraderSitsBetweenMomentumAndContrarianOnRisingPrice/,
      /runAutoMarketStep_swingTraderTakesProfitAfterLargeUnrealizedGain/,
    ],
    LONG_TERM_HOLDER: [
      /orderCount_longTermHolderTradesLessOftenThanDayTrader/,
      /runAutoMarketStep_longTermHolderDeepLossAndNoCashDoesNotSell/,
      /runAutoMarketStep_longTermHolderLargeGainDoesNotTakeProfitImmediately/,
    ],
    PAYDAY_ACCUMULATOR: [
      /buyBias_paydayAccumulatorKeepsHigherBuyBiasThanNoiseTraderOnNeutralSignal/,
      /fundRecurringCash_paydayAccumulatorWithoutDirectRecurringCashSettingDoesNotDeposit/,
      /runAutoMarketStep_paydayAccumulatorDepositsAndBuysWhenNoHoldingExists/,
      /fundRecurringCash_paydayAccumulatorDepositsOnlyAfterConfiguredInterval/,
    ],
    DIVIDEND_REINVESTOR: [
      /buyBias_dividendReinvestorHasNoRecurringCashByDefault/,
      /dividendReinvestorBehavior_recentDividendPaymentRaisesBuyBiasAndOrderCount/,
      /runAutoMarketStep_dividendReinvestorBuysAfterDividendPaymentWithoutRecurringCash/,
      /fundRecurringCash_dividendReinvestorDoesNotReceiveRecurringCash/,
    ],
    LIMIT_DOWN_TRAPPED: [
      /buyBias_limitDownTrappedAvoidsSellingMoreThanPanicSellerWhenDeeplyLosing/,
      /runAutoMarketStep_limitDownTrappedDeepLossAndNoCashDoesNotForceSell/,
      /runAutoMarketStep_limitDownTrappedAtLowerLimitAveragesDownWithoutSelling/,
    ],
    AVERAGE_DOWN_BUYER: [
      /buyBias_averageDownBuyerBuysLosingPositionMoreThanDipBuyer/,
      /runAutoMarketStep_averageDownBuyerBuysLosingPosition/,
    ],
    STOP_LOSS_TRADER: [
      /buyBias_stopLossTraderSellsLosingPositionMoreThanLossAverseProfile/,
      /runAutoMarketStep_stopLossTraderSellsLosingPosition/,
    ],
    FOMO_BUYER: [
      /buyBias_fomoBuyerChasesRallyAndBuyCrowdMoreThanMomentumFollower/,
      /runAutoMarketStep_fomoBuyerChasesSharpRiseWithBuyOrder/,
    ],
    PANIC_SELLER: [
      /buyBias_panicSellerAndDipBuyer_reactOppositeOnSharpDrop/,
      /runAutoMarketStep_panicSellerSellsAfterSharpDropEvenWithCashAvailable/,
    ],
    DIP_BUYER: [
      /buyBias_panicSellerAndDipBuyer_reactOppositeOnSharpDrop/,
      /runAutoMarketStep_dipBuyerBuysAfterSharpDropEvenWithExistingHoldings/,
    ],
    PROFIT_LOCKER: [
      /buyBias_profitLockerSellsWinningPositionMoreThanScalper/,
      /runAutoMarketStep_profitLockerSellsWinningPosition/,
    ],
    LIQUIDITY_AVOIDANT: [
      /orderCount_observerAndLiquidityAvoidantCanStayIdleOnNeutralSignal/,
      /runAutoMarketStep_liquidityAvoidantKeepsSmallOrderEvenOnStrongSignal/,
    ],
    CASH_DEFENSIVE: [
      /orderCount_cashDefensiveCanStayIdleWhenNoiseTraderStillTrades/,
      /runAutoMarketStep_cashDefensiveStaysIdleOnNeutralSignal/,
    ],
    WHALE: [
      /quantityUpperBound_whaleUsesLargerSizeThanSmallDiversifier/,
      /runAutoMarketStep_whaleAndSmallDiversifierUseDifferentRuntimeOrderSizes/,
    ],
    SMALL_DIVERSIFIER: [
      /orderSizing_smallDiversifierUsesMoreOrdersButSmallerSizeThanWhale/,
      /runAutoMarketStep_whaleAndSmallDiversifierUseDifferentRuntimeOrderSizes/,
    ],
    OBSERVER: [
      /orderCount_observerAndLiquidityAvoidantCanStayIdleOnNeutralSignal/,
      /runAutoMarketStep_observerRespondsOnlyToStrongBuySignalWithSmallOrder/,
    ],
  };
}

function profileBehaviorMarkerMismatches(text, profiles) {
  const requiredMarkers = profileBehaviorMarkers();
  const mismatches = [];
  for (const profile of profiles) {
    const markers = requiredMarkers[profile];
    if (!markers) {
      mismatches.push(`${profile}: no marker contract`);
      continue;
    }
    const missingMarkers = markers.filter((marker) => !marker.test(text));
    if (missingMarkers.length) {
      mismatches.push(`${profile}: ${missingMarkers.length} missing marker(s)`);
    }
  }
  return mismatches;
}

function sameSet(left, right) {
  return diff(left, right).missing.length === 0 && diff(left, right).extra.length === 0;
}

function diff(left, right) {
  return {
    missing: left.filter((value) => !right.includes(value)),
    extra: right.filter((value) => !left.includes(value)),
  };
}

function formatDiff(detail) {
  const parts = [];
  if (detail.missing.length) {
    parts.push(`missing=${detail.missing.join(",")}`);
  }
  if (detail.extra.length) {
    parts.push(`extra=${detail.extra.join(",")}`);
  }
  return parts.length ? ` (${parts.join(" ")})` : "";
}
