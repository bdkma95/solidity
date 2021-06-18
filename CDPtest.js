var CDP = artifacts.require("CDP");

contract('CDP'), function(accounts) {
   
   it("should run every function in a normal environment with normal sleep data", function(fund) {
       return CDP.deployed().then(function(instance) {
           return instance.balance.call(accounts[0]);
       }).then(function(balance) {
           assert.equal(balance.valueOf(), 1000, "1000 wasn't in the account");
       });
   });
   
   it("should run every function in a normal environment with normal sleep data", function(repay) {
       return CDP.deployed().then(function(instance) {
           return instance.balance.call(accounts[0]);
       }).then(function(balance) {
           assert.equal(balance.valueOf(), 1000, "1000 wasn't in the account");
       });
   });
   
   it("should run every function in a normal environment with normal sleep data", function(findAvailableBorrow) {
       return CDP.deployed().then(function(instance) {
           return instance.balance.call(accounts[0]);
       }).then(function(balance) {
           assert.equal(balance.valueOf(), 1000, "1000 wasn't in the account");
       });
   });
   
   it("should run every function in a normal environment with normal sleep data", function(findAvailableWithdrawal) {
       return CDP.deployed().then(function(instance) {
           return instance.balance.call(accounts[0]);
       }).then(function(balance) {
           assert.equal(balance.valueOf(), 1000, "1000 wasn't in the account");
       });
   });
};
