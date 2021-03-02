const hre = require("hardhat");

async function main() {
  const tokensReceiver = "0xD614FCE2c73959EB083B04231f07a079F956B7BB"
  const Powder = await hre.ethers.getContractFactory("Powder");

    const powder = await Powder.deploy(tokensReceiver);
    await powder.deployed();
    console.log("Powder address:", powder);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
