const strategyTest = require("./shared/strategyTest");

describe("Test strategies", function () {

  let strategies = [
    { name: "StargateUsdt" },
    { name: "BiswapUsdcUsdt" },
    { name: "BiswapBusdUsdt" },
  ];

  for (let i = 0; i < strategies.length; i++) {
      let strategy = strategies[i];
      strategyTest(strategy.name);   
  }
});
