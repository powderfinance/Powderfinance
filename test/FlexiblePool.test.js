const { ethers } = require("hardhat")
const { BigNumber } = require("ethers")
const { expect } = require("chai")

const tenPow18 = BigNumber.from(10).pow(18)

const setNextBlockTimestamp = async(timestamp) => {
  const block = await ethers.provider.send("eth_getBlockByNumber", ["latest", false])
  const currentTs = parseInt(block.timestamp)
  const diff = timestamp - currentTs
  await ethers.provider.send("evm_increaseTime", [diff])
}

const getCurrentUnix = () => {
  return Math.floor(Date.now() / 1000)
}

const moveAtEpoch = async(start, duration, epoch) => {
  await setNextBlockTimestamp(start + duration * (epoch - 1))
  await ethers.provider.send("evm_mine", [])
}

const deployContract = async(name, args) => {
  const factory = await ethers.getContractFactory(name)
  const ctr = await factory.deploy(...(args || []))
  await ctr.deployed()

  return ctr
}

describe('Flexible Pool', function () {
  let staking
  let globalEpoch
  let powderToken
  let uniLP
  let rewardPool
  let flexiblePool
  let creator
  let userAddr

  const epochDuration = 604800
  const numberOfEpochs = 100
  const epochStart = getCurrentUnix() + 1000

  const distributedAmount = BigNumber.from(2000000).mul(tenPow18)
  const amount = BigNumber.from(100).mul(tenPow18)

  let snapshotId

  before(async function () {
    [creator, user] = await ethers.getSigners()
    userAddr = await user.getAddress()

    globalEpoch = (await deployContract("GlobalEpoch", [epochStart]))
    staking = (await deployContract("GlobalFlexiblePool", [globalEpoch.address]))

    powderToken = (await deployContract("ERC20Mock"))
    uniLP = (await deployContract("ERC20Mock"))

    rewardPool = (await deployContract("RewardFund", [creator.address, powderToken.address, creator.address]))
    flexiblePool = (await deployContract("FlexiblePool", [
      powderToken.address,
      uniLP.address,
      globalEpoch.address,
      staking.address,
      rewardPool.address,
      distributedAmount.div(numberOfEpochs),
      numberOfEpochs,
      0
    ]))

    await powderToken.mint(rewardPool.address, distributedAmount)
    await rewardPool.connect(creator).approveRewards(flexiblePool.address, distributedAmount)
  })

  beforeEach(async function () {
    snapshotId = await ethers.provider.send("evm_snapshot", [])
  })

  afterEach(async function () {
    await ethers.provider.send("evm_revert", [snapshotId])
  })

  describe('General Contract checks', function () {
    it('should be deployed', async function () {
      expect(staking.address).to.not.equal(0)
      expect(flexiblePool.address).to.not.equal(0)
      expect(powderToken.address).to.not.equal(0)
    })

    it('Get epoch PoolSize and distribute tokens', async function () {
      await depositUniLP(amount)
      await moveAtEpoch(epochStart, epochDuration, 3)
      const totalAmount = amount

      expect(await flexiblePool.getPoolSize(1)).to.equal(totalAmount)
      expect(await flexiblePool.getEpochStake(userAddr, 1)).to.equal(totalAmount)
      expect(await powderToken.allowance(rewardPool.address, flexiblePool.address)).to.equal(distributedAmount)
      expect(await globalEpoch.getCurrentEpoch()).to.equal(3)

      await flexiblePool.connect(user).harvest(1)
      expect(await powderToken.balanceOf(userAddr)).to.equal(distributedAmount.div(numberOfEpochs))
    })
  })

  describe('Contract Tests', function () {
    it('User harvest and mass Harvest', async function () {
      await depositUniLP(amount)
      const totalAmount = amount
      // initialize epochs meanwhile
      await moveAtEpoch(epochStart, epochDuration, 9)
      expect(await flexiblePool.getPoolSize(1)).to.equal(amount)

      expect(await flexiblePool.lastInitializedEpoch()).to.equal(0) // no epoch initialized
      await expect(flexiblePool.harvest(10)).to.be.revertedWith('This epoch is in the future')
      await expect(flexiblePool.harvest(3)).to.be.revertedWith('Harvest in order')
      await (await flexiblePool.connect(user).harvest(1)).wait()

      expect(await powderToken.balanceOf(userAddr)).to.equal(
        amount.mul(distributedAmount.div(numberOfEpochs)).div(totalAmount),
      )
      expect(await flexiblePool.connect(user).userLastEpochIdHarvested()).to.equal(1)
      expect(await flexiblePool.lastInitializedEpoch()).to.equal(1) // epoch 1 have been initialized

      await (await flexiblePool.connect(user).massHarvest()).wait()
      const totalDistributedAmount = amount.mul(distributedAmount.div(numberOfEpochs)).div(totalAmount).mul(7)
      expect(await powderToken.balanceOf(userAddr)).to.equal(totalDistributedAmount)
      expect(await flexiblePool.connect(user).userLastEpochIdHarvested()).to.equal(7)
      expect(await flexiblePool.lastInitializedEpoch()).to.equal(7) // epoch 7 have been initialized
    })
    it('Have nothing to harvest', async function () {
      await depositUniLP(amount)
      await moveAtEpoch(epochStart, epochDuration, 30)
      expect(await flexiblePool.getPoolSize(1)).to.equal(amount)
      await flexiblePool.connect(creator).harvest(1)
      expect(await powderToken.balanceOf(await creator.getAddress())).to.equal(0)
      await flexiblePool.connect(creator).massHarvest()
      expect(await powderToken.balanceOf(await creator.getAddress())).to.equal(0)
    })
    it('harvest maximum 100 epochs', async function () {
      await depositUniLP(amount)
      const totalAmount = amount
      await moveAtEpoch(epochStart, epochDuration, 300)

      expect(await flexiblePool.getPoolSize(1)).to.equal(totalAmount)
      await (await flexiblePool.connect(user).massHarvest()).wait()
      expect(await flexiblePool.lastInitializedEpoch()).to.equal(numberOfEpochs)
    })
    it('gives epochid = 0 for previous epochs', async function () {
      await moveAtEpoch(epochStart, epochDuration, -2)
      expect(await globalEpoch.getCurrentEpoch()).to.equal(0)
    })
    it('it should return 0 if no deposit in an epoch', async function () {
      await moveAtEpoch(epochStart, epochDuration, 3)
      await flexiblePool.connect(user).harvest(1)
      expect(await powderToken.balanceOf(await user.getAddress())).to.equal(0)
    })
  })

  describe('Events', function () {
    it('Harvest emits Harvest', async function () {
      await depositUniLP(amount)
      await moveAtEpoch(epochStart, epochDuration, 9)

      await expect(flexiblePool.connect(user).harvest(1))
        .to.emit(flexiblePool, 'Harvest')
    })

    it('MassHarvest emits MassHarvest', async function () {
      await depositUniLP(amount)
      await moveAtEpoch(epochStart, epochDuration, 9)

      await expect(flexiblePool.connect(user).massHarvest())
        .to.emit(flexiblePool, 'MassHarvest')
    })
  })

  async function depositUniLP(x, u = user) {
    const ua = await u.getAddress()
    await uniLP.mint(ua, x)
    await uniLP.connect(u).approve(staking.address, x)
    return await staking.connect(u).deposit(uniLP.address, x)
  }
})