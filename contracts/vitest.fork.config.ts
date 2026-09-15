import { dirname, join } from "node:path";
import { defineConfig } from "vitest/config";
import {
  vitestSetupFilePath,
  getClarinetVitestsArgv,
} from "@stacks/clarinet-sdk/vitest";

/*
  Mainnet-fork tests (`npm run test:fork`).

  Each test opens its own empty simnet session forked from mainnet with
  `simnet.initEmptySession`, so the default setup file, which reloads the
  project session before every test, is left out. Only its Clarity value
  matchers are loaded.
*/

export default defineConfig({
  test: {
    environment: "clarinet",
    pool: "forks",
    isolate: false,
    maxWorkers: 1,
    include: ["tests-fork/**/*.test.ts"],
    setupFiles: [join(dirname(vitestSetupFilePath), "clarityValuesMatchers.ts")],
    // The first run fetches mainnet state over the network.
    testTimeout: 300_000,
    hookTimeout: 300_000,
    environmentOptions: {
      clarinet: {
        ...getClarinetVitestsArgv(),
      },
    },
  },
});
