const { expect } = require("chai")
const {
  BN, // Big Number support
  constants, // Common constants, like the zero address and largest integers
  expectEvent, // Assertions for emitted events
  expectRevert, // Assertions for transactions that should fail
  time,
} = require("@openzeppelin/test-helpers")

describe("Powder finance contracts!", function() {
  let owner, governance, investor1, investor2, investor3, badActor, snapshotId
  const tranches = {
    flexible: 'flexible',
    junior: 0,
    senior: 1
  }

  this.powderToken = null
  this.stakingToken = null
  this.tranchesPool = null
  this.flexiblePool = null
  this.consolidation = null
  this.globalEpoch = null
  this.globalFlexiblePool = null
  this.rewardFunds = null

  const toWei = (amount) => {
    return ethers.utils.parseEther(amount.toString())
  }

  const deposit = async (user, amount, trancheType) => {
    this.stakingToken = this.stakingToken.connect(user)
    const weiAmount = toWei(amount)

    if (trancheType === tranches.flexible) {
      this.globalFlexiblePool = this.globalFlexiblePool.connect(user)
      await this.stakingToken.approve(this.globalFlexiblePool.address, weiAmount)
      await this.globalFlexiblePool.deposit(this.stakingToken.address, weiAmount)
    } else {
      this.tranchesPool = this.tranchesPool.connect(user)
      await this.stakingToken.approve(this.tranchesPool.address, weiAmount)
      await this.tranchesPool.deposit(weiAmount, trancheType)
    }
  }

  const withdraw = async (user, epochId, amount, trancheType) => {
    if (trancheType === tranches.flexible) {
      const weiAmount = toWei(amount)
      this.globalFlexiblePool = this.globalFlexiblePool.connect(user)
      await this.globalFlexiblePool.withdraw(this.stakingToken.address, weiAmount)
    } else {
      this.tranchesPool = this.tranchesPool.connect(user)
      await this.tranchesPool.withdraw(epochId, trancheType)
    }
  }

  const flexibleEmergencyExit = async (user) => {
    this.globalFlexiblePool = this.globalFlexiblePool.connect(user)
    await this.globalFlexiblePool.emergencyWithdraw(this.stakingToken.address)
  }

  const claimReward = async (user, epochId, trancheType) => {
    if (trancheType === tranches.flexible) {
      this.flexiblePool = this.flexiblePool.connect(user)
      await this.globalFlexiblePool.harvest(epochId)
    } else {
      this.tranchesPool = this.tranchesPool.connect(user)
      await this.tranchesPool.clamReward(epochId, trancheType)
    }
  }

  const airdropStakingToken = async (receiver, amount) => {
    this.stakingToken = this.stakingToken.connect(owner)
    await this.stakingToken.transfer(receiver, toWei(amount))
  }

  const airdropPowderToken = async (receiver, amount) => {
    this.powderToken = this.powderToken.connect(owner)
    await this.stakingToken.transfer(receiver, toWei(amount))
  }

  const deployMockContracts = async () => {
    const GlobalFlexiblePool = await ethers.getContractFactory("GlobalFlexiblePool")
    const FlexiblePool = await ethers.getContractFactory("FlexiblePool")
    const TranchesPool = await ethers.getContractFactory("TranchesPool")
    const RewardFund = await ethers.getContractFactory("RewardFund")
    const Powder = await ethers.getContractFactory("Powder")
    const GlobalEpoch = await ethers.getContractFactory("GlobalEpoch")
    const Consolidation = await ethers.getContractFactory("Consolidation");

    [owner, governance, investor1, investor2, investor3, badActor] = await ethers.getSigners()

    // 1: Deploy global epoch contract
    const currentTime = (await time.latest()).toString()
    this.globalEpoch = await GlobalEpoch.deploy(parseInt(currentTime) + parseInt(time.duration.days(1)))
    await this.globalEpoch.deployed()

    // 2: Deploy global flexible pool contract
    this.globalFlexiblePool = await GlobalFlexiblePool.deploy(this.globalEpoch.address)
    await this.globalFlexiblePool.deployed()

    // 3: Deploy consolidation contract
    this.consolidation = await Consolidation.deploy()
    await this.consolidation.deployed()

    // 4: Deploy Powder token contract
    this.powderToken = await Powder.deploy(owner.address)
    await this.consolidation.deployed()

    // 5: Deploy reward pool contract
    this.rewardFunds = await RewardFund.deploy(owner.address, this.powderToken.address, governance.address)
    await this.rewardFunds.deployed()

    // 6: Deploy staking token
    this.stakingToken = await Powder.deploy(owner.address)
    await this.stakingToken.deployed()

    // 7: Deploy tranches pool
    this.tranchesPool = await TranchesPool.deploy(
      this.powderToken.address,
      this.stakingToken.address,
      this.globalEpoch.address,
      this.rewardFunds.address,
      this.consolidation.address,
      toWei(1000), // Reward per epoch
      25,
      0,  // Started from global Epoch Id 1
    )
    await this.tranchesPool.deployed()

    // 8: Deploy flexible pool
    this.flexiblePool = await FlexiblePool.deploy(
      this.powderToken.address,
      this.stakingToken.address,
      this.globalEpoch.address,
      this.globalFlexiblePool.address,
      this.rewardFunds.address,
      toWei(5000), // Reward per epoch
      25,
      0
    )
    await this.flexiblePool.deployed()

    await airdropStakingToken(investor1.address, 500)
    await airdropStakingToken(investor2.address, 500)
    await airdropStakingToken(investor3.address, 500)
    await airdropPowderToken(this.rewardFunds.address, 100000)
  }

  // ------------------
  // TESTS
  // ------------------


  before(async () => {
    await deployMockContracts()
    snapshotId = await ethers.provider.send("evm_snapshot", []);
  })

  describe("Flexible pool", async () => {
    it("Should revert if amount is 0", async () => {
      // Should failed
      await expectRevert(
        deposit(investor1, 0, tranches.flexible),
        "deposit: Amount must be > 0",
      );
    })

    it("Should revert if approval is 0", async () => {
      // Should failed
      await expectRevert(
        this.globalFlexiblePool.deposit(this.stakingToken.address, toWei(500)),
        "deposit: Token allowance too small!",
      );
    })

    it("Saves users deposit in state", async () => {
      await deposit(investor1, 100, tranches.flexible)

      const poolSize = await this.globalFlexiblePool.getEpochPoolSize(this.stakingToken.address, 1)
      const balance = await this.globalFlexiblePool.balanceOf(investor1.address, this.stakingToken.address)

      expect(balance.toString()).to.be.equal(toWei(100))
      expect(poolSize.toString()).to.be.equal(toWei(100))
    });

    it("Check the state after withdraw", async () => {
      await withdraw(investor1, 0, 50, tranches.flexible)

      const poolSize = await this.globalFlexiblePool.getEpochPoolSize(this.stakingToken.address, 1)
      const balance = await this.globalFlexiblePool.balanceOf(investor1.address, this.stakingToken.address)

      expect(balance.toString()).to.be.equal(toWei(50))
      expect(poolSize.toString()).to.be.equal(toWei(50))
    })

    it("Should revert if withdraw amount is 0", async () => {
      // Should failed
      await expectRevert(
        withdraw(investor1, 0, 0, tranches.flexible),
        "withdraw: Amount must be > 0!",
      );
    })

    it("Should revert if amount is too big", async () => {
      // Should failed
      await expectRevert(
        withdraw(investor1, 0, 10000, tranches.flexible),
        "withdraw: Balance too small!",
      );
    })

    it("Should revert emergency exit", async () => {
      await deposit(investor2, 200, tranches.flexible)

      const poolSize = await this.globalFlexiblePool.getEpochPoolSize(this.stakingToken.address, 1)
      const balance = await this.globalFlexiblePool.balanceOf(investor2.address, this.stakingToken.address)

      expect(balance.toString()).to.be.equal(toWei(200))
      expect(poolSize.toString()).to.be.equal(toWei(250))

      await expectRevert(
        flexibleEmergencyExit(investor2),
        "emergencyWithdraw: At least 10 epochs must pass without success!",
      )
    })

    it("Increase time with 12 epoch", async () => {
      await time.increase(time.duration.days(85))
    })

    it("Call emergency exit", async () => {
      await flexibleEmergencyExit(investor2)
      const balance = await this.globalFlexiblePool.balanceOf(investor2.address, this.stakingToken.address)
      expect(balance.toString()).to.be.equal(toWei(0))
    })
  })
})
