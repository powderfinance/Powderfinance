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

describe('Tranches Pool', function () {
  let globalEpoch
  let powderToken
  let uniLP
  let rewardPool
  let tranchePool
  let consolidation
  let creator
  let userAddr

  const epochDuration = 604800
  const numberOfEpochs = 100
  const epochStart = getCurrentUnix() + 1000

  const distributedAmount = BigNumber.from(500000).mul(tenPow18)
  const amount = BigNumber.from(1000).mul(tenPow18)

  let snapshotId

  before(async function () {
    [creator, user] = await ethers.getSigners()
    userAddr = await user.getAddress()

    globalEpoch = (await deployContract("GlobalEpoch", [epochStart]))
    staking = (await deployContract("GlobalFlexiblePool", [globalEpoch.address]))

    powderToken = (await deployContract("ERC20Mock"))
    uniLP = (await deployContract("ERC20Mock"))
    consolidation = (await deployContract("Consolidation"))

    rewardPool = (await deployContract("RewardFund", [creator.address, powderToken.address, creator.address]))
    tranchePool = (await deployContract("TranchesPool", [
      powderToken.address,
      uniLP.address,
      globalEpoch.address,
      rewardPool.address,
      consolidation.address,
      distributedAmount.div(numberOfEpochs),
      numberOfEpochs,
      10
    ]))

    await powderToken.mint(rewardPool.address, distributedAmount)
    await rewardPool.connect(creator).approveRewards(tranchePool.address, distributedAmount)
  })

  beforeEach(async function () {
    snapshotId = await ethers.provider.send("evm_snapshot", [])
  })

  afterEach(async function () {
    await ethers.provider.send("evm_revert", [snapshotId])
  })

  describe('General Contract checks', function () {
    it('should be deployed', async function () {
      expect(consolidation.address).to.not.equal(0)
      expect(tranchePool.address).to.not.equal(0)
      expect(powderToken.address).to.not.equal(0)
      expect(uniLP.address).to.not.equal(0)
    })

    it('deposit and check the state', async function () {
      await expect(depositUniLP(amount, 1)).to.be.revertedWith('deposit: Not started yet!')
      await setNextBlockTimestamp(epochStart)
      await expect(depositUniLP(amount, 1)).to.be.revertedWith('deposit: Only junior tranche accepted now!')

      await depositUniLP(amount, 0)

      let data = await tranchePool.getEpochData(1)
      let userData = await tranchePool.getUserBalances(userAddr, 1)

      expect(data.juniorStaked.toString()).to.equal(amount.toString())
      expect(data.seniorStaked.toString()).to.equal('0')
      expect(data.juniorResult.toString()).to.equal('0')
      expect(data.seniorResult.toString()).to.equal('0')

      expect(userData.juniorStaked.toString()).to.equal(amount)
      expect(userData.seniorStaked.toString()).to.equal('0')

      await setNextBlockTimestamp(getCurrentUnix() + (2 * 60 * 60 * 24)) // +2 days
      await expect(depositUniLP(amount, 0)).to.be.revertedWith('deposit: Not junior stake period!')

      await depositUniLP(amount.mul(3), 1)
      await expect(depositUniLP(amount.mul(10), 1)).to.be.revertedWith('deposit: Senior pool limit is reached!')
      await depositUniLP(amount.mul(2), 1);

      // Check consolidation balance
      expect(await consolidation.getBalance(tranchePool.address, uniLP.address)).to.equal(amount.mul(6))

      data = await tranchePool.getEpochData(1)
      userData = await tranchePool.getUserBalances(userAddr, 1)

      expect(data.juniorStaked.toString()).to.equal(amount.toString())
      expect(data.seniorStaked.toString()).to.equal(amount.mul(5).toString())
      expect(data.juniorResult.toString()).to.equal('0')
      expect(data.seniorResult.toString()).to.equal('0')

      expect(userData.juniorStaked.toString()).to.equal(amount)
      expect(userData.seniorStaked.toString()).to.equal(amount.mul(5))

      await moveAtEpoch(epochStart, epochDuration, 2)
      await expect(await globalEpoch.isJuniorStakePeriod()).to.be.equal(true)
      await expect(await globalEpoch.getCurrentEpoch()).to.be.equal('2')

      await expect(withdrawUniLP(1, 0)).to.be.revertedWith('withdraw: Results not posted!')
      await tranchePool.postResults(1, BigNumber.from(1005).mul(tenPow18), BigNumber.from(4995).mul(tenPow18))

      let balanceBefore = await uniLP.balanceOf(userAddr)
      await withdrawUniLP(1, 0)
      let balanceAfter = await uniLP.balanceOf(userAddr)
      expect(balanceAfter.sub(balanceBefore)).to.equal(BigNumber.from(1005).mul(tenPow18))

      // Check consolidation balance
      expect(await consolidation.getBalance(tranchePool.address, uniLP.address)).to.equal(BigNumber.from(4995).mul(tenPow18))

      balanceBefore = await uniLP.balanceOf(userAddr)
      await withdrawUniLP(1, 0)
      balanceAfter = await uniLP.balanceOf(userAddr)
      expect(balanceAfter.sub(balanceBefore)).to.equal('0')

      await expect(withdrawUniLP(1000, 0)).to.be.revertedWith('withdraw: This epoch is in the future!')

      // After first withdraw available tokens amount should be 0
      balanceBefore = await uniLP.balanceOf(userAddr)
      await withdrawUniLP(1, 1)
      balanceAfter = await uniLP.balanceOf(userAddr)
      expect(balanceAfter.sub(balanceBefore)).to.equal(BigNumber.from(4995).mul(tenPow18))

      // Claim JUNIOR rewards
      balanceBefore = await powderToken.balanceOf(userAddr)
      await withdrawRewards(1, 0)
      balanceAfter = await powderToken.balanceOf(userAddr)
      expect(balanceAfter.sub(balanceBefore)).to.equal('4999958664021164020000')

      // Claim second time will be without result
      balanceBefore = await powderToken.balanceOf(userAddr)
      await withdrawRewards(1, 0)
      balanceAfter = await powderToken.balanceOf(userAddr)
      expect(balanceAfter.sub(balanceBefore)).to.equal('0')

      // Claim SENIOR rewards
      balanceBefore = await powderToken.balanceOf(userAddr)
      await withdrawRewards(1, 1)
      balanceAfter = await powderToken.balanceOf(userAddr)
      // expect(balanceAfter.sub(balanceBefore)).to.equal('3579626322751322750000')

      // Claim second time will be without result
      balanceBefore = await powderToken.balanceOf(userAddr)
      await withdrawRewards(1, 1)
      balanceAfter = await powderToken.balanceOf(userAddr)
      expect(balanceAfter.sub(balanceBefore)).to.equal('0')
    })
  })

  describe('General Contract checks', function () {
    it('deposit and check the state', async function () {
      await expect(depositUniLP(amount, 1)).to.be.revertedWith('deposit: Not started yet!')
      await setNextBlockTimestamp(epochStart)
      await expect(depositUniLP(amount, 1)).to.be.revertedWith('deposit: Only junior tranche accepted now!')

      await depositUniLP(amount, 0)

      let data = await tranchePool.getEpochData(1)
      let userData = await tranchePool.getUserBalances(userAddr, 1)

      expect(data.juniorStaked.toString()).to.equal(amount.toString())
      expect(data.seniorStaked.toString()).to.equal('0')
      expect(data.juniorResult.toString()).to.equal('0')
      expect(data.seniorResult.toString()).to.equal('0')

      expect(userData.juniorStaked.toString()).to.equal(amount)
      expect(userData.seniorStaked.toString()).to.equal('0')

      await setNextBlockTimestamp(getCurrentUnix() + (2 * 60 * 60 * 24)) // +2 days
      await expect(depositUniLP(amount, 0)).to.be.revertedWith('deposit: Not junior stake period!')

      await depositUniLP(amount.mul(1), 1)
      await expect(depositUniLP(amount.mul(10), 1)).to.be.revertedWith('deposit: Senior pool limit is reached!')

      // Check consolidation balance
      expect(await consolidation.getBalance(tranchePool.address, uniLP.address)).to.equal(amount.mul(2))

      data = await tranchePool.getEpochData(1)
      userData = await tranchePool.getUserBalances(userAddr, 1)

      expect(data.juniorStaked.toString()).to.equal(amount.toString())
      expect(data.seniorStaked.toString()).to.equal(amount.toString())
      expect(data.juniorResult.toString()).to.equal('0')
      expect(data.seniorResult.toString()).to.equal('0')

      expect(userData.juniorStaked.toString()).to.equal(amount)
      expect(userData.seniorStaked.toString()).to.equal(amount)

      await moveAtEpoch(epochStart, epochDuration, 2)
      await expect(await globalEpoch.isJuniorStakePeriod()).to.be.equal(true)
      await expect(await globalEpoch.getCurrentEpoch()).to.be.equal('2')

      await expect(withdrawUniLP(1, 0)).to.be.revertedWith('withdraw: Results not posted!')
      await tranchePool.postResults(1, BigNumber.from(990).mul(tenPow18), BigNumber.from(1010).mul(tenPow18))

      let balanceBefore = await uniLP.balanceOf(userAddr)
      await withdrawUniLP(1, 0)
      let balanceAfter = await uniLP.balanceOf(userAddr)
      expect(balanceAfter.sub(balanceBefore)).to.equal(BigNumber.from(990).mul(tenPow18))

      // Check consolidation balance
      expect(await consolidation.getBalance(tranchePool.address, uniLP.address)).to.equal(BigNumber.from(1010).mul(tenPow18))

      balanceBefore = await uniLP.balanceOf(userAddr)
      await withdrawUniLP(1, 0)
      balanceAfter = await uniLP.balanceOf(userAddr)
      expect(balanceAfter.sub(balanceBefore)).to.equal('0')

      await expect(withdrawUniLP(1000, 0)).to.be.revertedWith('withdraw: This epoch is in the future!')

      // After first withdraw available tokens amount should be 0
      balanceBefore = await uniLP.balanceOf(userAddr)
      await withdrawUniLP(1, 1)
      balanceAfter = await uniLP.balanceOf(userAddr)
      expect(balanceAfter.sub(balanceBefore)).to.equal(BigNumber.from(1010).mul(tenPow18))

      // Claim JUNIOR rewards
      balanceBefore = await powderToken.balanceOf(userAddr)
      await withdrawRewards(1, 0)
      balanceAfter = await powderToken.balanceOf(userAddr)
      expect(balanceAfter.sub(balanceBefore)).to.equal('4999958664021164020000')

      // Claim second time will be without result
      balanceBefore = await powderToken.balanceOf(userAddr)
      await withdrawRewards(1, 0)
      balanceAfter = await powderToken.balanceOf(userAddr)
      expect(balanceAfter.sub(balanceBefore)).to.equal('0')

      // Claim SENIOR rewards
      balanceBefore = await powderToken.balanceOf(userAddr)
      await withdrawRewards(1, 1)
      balanceAfter = await powderToken.balanceOf(userAddr)
      // expect(balanceAfter.sub(balanceBefore)).to.equal('3579626322751322750000')

      // Claim second time will be without result
      balanceBefore = await powderToken.balanceOf(userAddr)
      await withdrawRewards(1, 1)
      balanceAfter = await powderToken.balanceOf(userAddr)
      expect(balanceAfter.sub(balanceBefore)).to.equal('0')
    })
  })

  async function depositUniLP(amount, tranche, u = user) {
    const ua = await u.getAddress()
    await uniLP.mint(ua, amount)
    await uniLP.connect(u).approve(tranchePool.address, amount)
    return await tranchePool.connect(u).deposit(amount, tranche)
  }

  async function withdrawUniLP(epochId, tranche, u = user) {
    return await tranchePool.connect(u).withdraw(epochId, tranche)
  }

  async function withdrawRewards(epochId, tranche, u = user) {
    return await tranchePool.connect(u).clamReward(epochId, tranche)
  }
})