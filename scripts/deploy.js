const getCurrentUnix = () => {
  return Math.floor(Date.now() / 1000)
}

const deployContract = async (name, args) => {
  const factory = await ethers.getContractFactory(name)
  const ctr = await factory.deploy(...(args || []))
  await ctr.deployed()
  return ctr
}

async function main() {

  /// ---------
  /// Owner and access params
  /// ---------

  const adminAddress = '0x1234E407A33d9000342aD6F44a3Db73BbA0Fc9CF' // <---- Put admin address here

  /// ---------
  /// Params
  /// ---------

  const epochStart = getCurrentUnix() + 100 // First epoch after 100 seconds
  const [deployer] = await ethers.getSigners()
  const networkId = ((await ethers.provider.getNetwork()).chainId).toString()

  const mainnetPowderToken = { address: '0xe62a6671877260705e6593bc0bff3324e3d4e995' }
  const mainnetCDaiToken = { address: '0x5d3a536E4D6DbD6114cc1Ead35777bAB948E3643' }

  const cDaiPool = {
    flexible: {
      rewardsPerEpoch: '500000' + '000000000000000000', // 500,000 POWDER
      epochsCount: '100'
    },
    tranches: {
      rewardsPerEpoch: '100000' + '000000000000000000', // 100,000 POWDER
      epochsCount: '100'
    }
  }

  /// ---------
  /// Deployments
  /// ---------

  const consolidation = await deployContract("Consolidation", [])
  console.log('1) Consolidation:', consolidation.address)

  const globalEpoch = await deployContract("GlobalEpoch", [epochStart])
  console.log('2) Global epoch:', globalEpoch.address)

  const globalFlexiblePool = await deployContract("GlobalFlexiblePool", [globalEpoch.address])
  console.log('3) Global flexible pool:', globalFlexiblePool.address)

  const powder = networkId === '1' ? mainnetPowderToken : await deployContract("Powder", [adminAddress])
  console.log('4) Powder token:', powder.address)

  const cDaiToken = networkId === '1' ? mainnetCDaiToken : await deployContract("LpToken", ['CDai token', 'CDAI'])
  console.log('5) CDai token:', cDaiToken.address)

  const rewardFund = await deployContract("RewardFund", [adminAddress, powder.address, adminAddress])
  console.log('6) Reward fund:', rewardFund.address)

  const flexiblePool = await deployContract("FlexiblePool", [
    powder.address,
    cDaiToken.address,
    globalEpoch.address,
    globalFlexiblePool.address,
    rewardFund.address,
    cDaiPool.flexible.rewardsPerEpoch,
    cDaiPool.flexible.epochsCount,
    '0'
  ])
  console.log('7) CDai Flexible pool:', flexiblePool.address)

  const tranchesPool = await deployContract("TranchesPool", [
    powder.address,
    cDaiToken.address,
    globalEpoch.address,
    rewardFund.address,
    consolidation.address,
    cDaiPool.tranches.rewardsPerEpoch,
    cDaiPool.tranches.epochsCount,
    '0'
  ])
  console.log('7) CDai Tranches pool:', tranchesPool.address)

  await tranchesPool.transferOwnership(adminAddress)
  console.log('8) Tranches pool ownership transferred!')
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
