#!/usr/bin/env node

import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const root = new URL("..", import.meta.url).pathname;

const paths = {
  profileType: "stock-batch-service/src/main/java/stock/batch/service/batch/automarket/model/AutoParticipantProfileType.java",
  modelVersion: "stock-batch-service/src/main/java/stock/batch/service/batch/automarket/model/AutoParticipantBehaviorModelVersion.java",
  definitionCatalog: "stock-batch-service/src/main/java/stock/batch/service/automarket/v5/profile/V5ProfileDefinitionCatalog.java",
  algorithmCatalog: "stock-batch-service/src/main/java/stock/batch/service/automarket/v5/profile/V5ProfileAlgorithmCatalog.java",
  registry: "stock-batch-service/src/main/java/stock/batch/service/automarket/v5/profile/V5ProfileRegistry.java",
  thoughtEngine: "stock-batch-service/src/main/java/stock/batch/service/automarket/v5/profile/V5ThoughtEngine.java",
  cancellationCatalog: "stock-batch-service/src/main/java/stock/batch/service/automarket/v5/cancellation/V5CancellationPolicyCatalog.java",
  cancellationPlanner: "stock-batch-service/src/main/java/stock/batch/service/automarket/v5/cancellation/V5CancellationPlanner.java",
  contractTest: "stock-batch-service/src/test/java/stock/batch/service/automarket/v5/profile/V5ProfileRegistryContractTest.java",
  cancellationTest: "stock-batch-service/src/test/java/stock/batch/service/automarket/v5/cancellation/V5CancellationPlannerTest.java",
  migration: "stock-back-service/src/main/resources/db/ddl/stock_auto_participant_v5_fresh_start_alter.sql",
  frontTypes: "stock-front-service/app/types/stockAutomation.ts",
  frontPanel: "stock-front-service/app/supply-demand/admin/AdminAutoParticipantV5OperationsPanel.tsx",
};

const files = Object.fromEntries(
  Object.entries(paths).map(([key, path]) => [key, read(path)]),
);

const profileTypes = parseProfileTypes(files.profileType);
const definitions = matches(files.definitionCatalog, /AutoParticipantProfileType\.([A-Z_]+),\s*"([A-Z0-9_]+)"/g);
const definitionTypes = definitions.map((match) => match[1]);
const algorithmIds = definitions.map((match) => match[2]);
const algorithmCases = matches(files.algorithmCatalog, /case\s+([A-Z_]+)\s*->/g)
  .map((match) => match[1])
  .filter((value) => profileTypes.includes(value));
const cancellationCatalogCases = matches(files.cancellationCatalog, /case\s+([A-Z_]+)\s*->/g).map((match) => match[1]);
const cancellationPlannerCases = matches(files.cancellationPlanner, /case\s+([A-Z_]+)\s*->/g).map((match) => match[1]);

const liveRoots = [
  "stock-batch-service/src/main/java",
  "stock-back-service/src/main/java",
  "stock-front-service/app",
];
const liveFiles = liveRoots.flatMap(listFiles);
const liveText = liveFiles.map(read).join("\n");

const checks = [
  ["exactly 27 automatic-participant profile types exist", profileTypes.length === 27],
  ["V5 definition catalog covers every profile exactly once", sameSet(profileTypes, definitionTypes) && unique(definitionTypes).length === 27],
  ["every profile owns a unique algorithm id", unique(algorithmIds).length === 27],
  ["V5 algorithm catalog has one explicit branch per profile", sameSet(profileTypes, algorithmCases) && unique(algorithmCases).length === 27],
  ["V5 registry rejects missing or duplicate algorithms", includesAll(files.registry, [
    "Duplicate V5 profile behavior",
    "Duplicate V5 algorithm id",
    "Missing V5 profile behaviors",
    "V5 profile requires contextual thoughts",
  ])],
  ["thoughts are selected contextually instead of evaluating the full catalog", includesAll(files.thoughtEngine, [
    "V5_THOUGHT_SELECTION",
    "definition.core(type)",
    "optionalThoughtProbability()",
    "context.persona().curiosity()",
    "fatiguePenalty",
  ]) && !files.thoughtEngine.includes("V5ThoughtType.values()")],
  ["profile contract proves coverage, replay, contextual subsets, surprise, and side feasibility", includesAll(files.contractTest, [
    "createDefault_registersTwentySevenUniqueAlgorithms",
    "decide_everyProfileIsReplayableAndUsesOnlyItsSupportedThoughts",
    "thoughtSelection_sameProfileChangesWithParticipantAndEvent",
    "surprise_everyProfileCanOccasionallyProduceBoundedDeterministicVariation",
    "decision_neverChoosesAnInfeasibleSideEvenWhenSurpriseOccurs",
    "noiseTrader_infeasibleSampledSell_doesNotBecomeBuy",
  ])],
  ["cancellation policy and thought branches cover all 27 profiles", sameSet(profileTypes, cancellationCatalogCases)
    && unique(cancellationCatalogCases).length === 27
    && sameSet(profileTypes, cancellationPlannerCases)
    && unique(cancellationPlannerCases).length === 27],
  ["cancellation is deterministic, profile-aware, and context-driven", includesAll(files.cancellationPlanner, [
    "Only V5 orders can enter V5 cancellation review",
    "CANCELLATION_REVIEW",
    "cancellationPressure",
    "priceDrift",
    "fillRatio",
    "PROFILE_RECONSIDERATION",
  ]) && includesAll(files.cancellationTest, [
    "policyCatalog_allProfilesHaveUniqueCancellationAlgorithms",
    "decide_sameLedgerContext_replaysExactly",
    "decide_everyProfileCanCancelFromItsOwnDynamicReview",
  ])],
  ["the live Java model version is V5-only", /enum\s+AutoParticipantBehaviorModelVersion\s*\{\s*V5\s*;/.test(files.modelVersion)],
  ["fresh migration removes population amplification and permits only V5 live configuration", includesAll(files.migration, [
    "V5 is a destructive, independent start",
    "DROP COLUMN represented_participant_count",
    "DROP COLUMN population_weight",
    "behavior_model_version = 'V5'",
    "CREATE TABLE stock_auto_participant_v5_daily_state",
    "CREATE TABLE stock_auto_participant_v5_order_schedule",
  ])],
  ["frontend exposes only the V5 model and the 1:1 operating contract", includesAll(files.frontTypes + files.frontPanel, [
    'AutoParticipantBehaviorModelVersion = "V5"',
    "실제 계좌의 주문과 수량을 1:1로 기록",
    "대표인구 가중치나 코호트 증폭을 사용하지 않습니다.",
    "autoSubmittedQuantity",
    "autoExecutedGrossQuantity",
    "targetAutoSubmittedOrderCount",
  ])],
  ["no executable previous-model source directory remains", !existsSync(join(root, "stock-batch-service/src/main/java/stock/batch/service/automarket/v4"))
    && liveFiles.every((path) => !/(^|\/)v4(\/|$)|V4/.test(relative(root, path)))],
  ["live source contains no represented-population or population-weight field", !/representedParticipant|represented_participant|populationWeight|population_weight/.test(liveText)],
];

let failed = 0;
for (const [label, passed] of checks) {
  if (passed) {
    console.log(`PASS ${label}`);
  } else {
    failed += 1;
    console.error(`FAIL ${label}`);
  }
}

if (failed > 0) {
  console.error(`\n${failed} V5 profile contract check(s) failed.`);
  process.exit(1);
}

console.log(`\nVerified ${profileTypes.length} independent V5 profile algorithms.`);

function read(path) {
  return readFileSync(join(root, path), "utf8");
}

function listFiles(path) {
  const absolute = join(root, path);
  if (!existsSync(absolute)) {
    return [];
  }
  return readdirSync(absolute).flatMap((name) => {
    const child = join(absolute, name);
    return statSync(child).isDirectory()
      ? listFiles(relative(root, child))
      : [relative(root, child)];
  });
}

function parseProfileTypes(text) {
  const body = text.match(/public\s+enum\s+AutoParticipantProfileType\s*\{([\s\S]*?);/)?.[1] ?? "";
  return body.match(/\b[A-Z][A-Z0-9_]*\b/g) ?? [];
}

function matches(text, pattern) {
  return [...text.matchAll(pattern)];
}

function unique(values) {
  return [...new Set(values)];
}

function sameSet(left, right) {
  return left.length === right.length
    && unique(left).length === unique(right).length
    && left.every((value) => right.includes(value));
}

function includesAll(text, values) {
  return values.every((value) => text.includes(value));
}
