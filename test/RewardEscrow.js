const RewardEscrow = artifacts.require('RewardEscrow');
const Synthetix = artifacts.require('Synthetix');
const FeePool = artifacts.require('FeePool');
const ExchangeRates = artifacts.require('ExchangeRates');

const { currentTime, fastForward, toUnit, ZERO_ADDRESS } = require('../utils/testUtils');

contract('RewardEscrow', async function(accounts) {
	const SECOND = 1000;
	const DAY = 86400;
	const WEEK = 604800;
	const YEAR = 31556926;

	const [SNX] = ['SNX'].map(web3.utils.asciiToHex);

	const [, owner, feePoolAccount, account1, account2] = accounts;
	let rewardEscrow, synthetix, exchangeRates, oracle;

	beforeEach(async function() {
		// Save ourselves from having to await deployed() in every single test.
		// We do this in a beforeEach instead of before to ensure we isolate
		// contract interfaces to prevent test bleed.
		synthetix = await Synthetix.deployed();
		rewardEscrow = await RewardEscrow.deployed();
		exchangeRates = await ExchangeRates.deployed();
		// Get the oracle address to send price updates when fastForwarding
		oracle = await exchangeRates.oracle();
	});

	describe('Constructor & Settings ', async function() {
		it('should set synthetix on contructor', async function() {
			const synthetixAddress = await rewardEscrow.synthetix();
			assert.equal(synthetixAddress, Synthetix.address);
		});

		it('should set feePool on contructor', async function() {
			const feePoolAddress = await rewardEscrow.feePool();
			assert.equal(feePoolAddress, FeePool.address);
		});

		it('should set owner on contructor', async function() {
			const ownerAddress = await rewardEscrow.owner();
			assert.equal(ownerAddress, owner);
		});

		it('should allow owner to set synthetix', async function() {
			await rewardEscrow.setSynthetix(ZERO_ADDRESS, { from: owner });
			const synthetixAddress = await rewardEscrow.synthetix();
			assert.equal(synthetixAddress, ZERO_ADDRESS);
		});

		it('should allow owner to set feePool', async function() {
			await rewardEscrow.setFeePool(ZERO_ADDRESS, { from: owner });
			const feePoolAddress = await rewardEscrow.feePool();
			assert.equal(feePoolAddress, ZERO_ADDRESS);
		});
	});

	describe('Functions', async function() {
		beforeEach(async function() {
			// Ensure only FeePool Address can call rewardEscrow.appendVestingEntry()
			await rewardEscrow.setFeePool(feePoolAccount, { from: owner });
			const feePoolAddress = await rewardEscrow.feePool();
			assert.equal(feePoolAddress, feePoolAccount);
		});

		describe('Vesting Schedule Writes', async function() {
			it('should not create a vesting entry with a zero amount', async function() {
				// Transfer of SNX to the escrow must occur before creating an entry
				await synthetix.transfer(RewardEscrow.address, toUnit('1'), { from: owner });

				await assert.revert(
					rewardEscrow.appendVestingEntry(account1, toUnit('0'), { from: feePoolAccount })
				);
			});

			it('should not create a vesting entry if there is not enough SNX in the contracts balance', async function() {
				// Transfer of SNX to the escrow must occur before creating an entry
				await synthetix.transfer(RewardEscrow.address, toUnit('1'), { from: owner });
				await assert.revert(
					rewardEscrow.appendVestingEntry(account1, toUnit('10'), { from: feePoolAccount })
				);
			});

			it('should not create more than MAX_VESTING_ENTRIES vesting entries', async function() {
				const MAX_VESTING_ENTRIES = 260; // await rewardEscrow.MAX_VESTING_ENTRIES();

				// Transfer of SNX to the escrow must occur before creating an entry
				await synthetix.transfer(RewardEscrow.address, toUnit('260'), { from: owner });

				// append the MAX_VESTING_ENTRIES to the schedule
				for (let i = 0; i < MAX_VESTING_ENTRIES; i++) {
					rewardEscrow.appendVestingEntry(account1, toUnit('1'), { from: feePoolAccount });
					await fastForward(WEEK);
				}
				// assert adding 1 more above the MAX_VESTING_ENTRIES fails
				await assert.revert(
					rewardEscrow.appendVestingEntry(account1, toUnit('1'), { from: feePoolAccount })
				);
			});
		});

		describe('Vesting Schedule Reads ', async function() {
			beforeEach(async function() {
				// Transfer of SNX to the escrow must occur before creating a vestinng entry
				await synthetix.transfer(RewardEscrow.address, toUnit('6000'), { from: owner });

				// Add a few vesting entries as the feepool address
				await rewardEscrow.appendVestingEntry(account1, toUnit('1000'), { from: feePoolAccount });
				await fastForward(WEEK);
				await rewardEscrow.appendVestingEntry(account1, toUnit('2000'), { from: feePoolAccount });
				await fastForward(WEEK);
				await rewardEscrow.appendVestingEntry(account1, toUnit('3000'), { from: feePoolAccount });
			});

			it('should append a vesting entry and increase the contracts balance', async function() {
				const balanceOfRewardEscrow = await synthetix.balanceOf(RewardEscrow.address);
				assert.bnEqual(balanceOfRewardEscrow, toUnit('6000'));
			});

			it('should get an accounts total Vested Account Balance', async function() {
				const balanceOf = await rewardEscrow.balanceOf(account1);
				assert.bnEqual(balanceOf, toUnit('6000'));
			});

			it('should get an accounts number of vesting entries', async function() {
				const numVestingEntries = await rewardEscrow.numVestingEntries(account1);
				assert.equal(numVestingEntries, 3);
			});

			it('should get an accounts vesting schedule entry by index', async function() {
				let vestingScheduleEntry;
				vestingScheduleEntry = await rewardEscrow.getVestingScheduleEntry(account1, 0);
				assert.bnEqual(vestingScheduleEntry[1], toUnit('1000'));

				vestingScheduleEntry = await rewardEscrow.getVestingScheduleEntry(account1, 1);
				assert.bnEqual(vestingScheduleEntry[1], toUnit('2000'));

				vestingScheduleEntry = await rewardEscrow.getVestingScheduleEntry(account1, 2);
				assert.bnEqual(vestingScheduleEntry[1], toUnit('3000'));
			});

			it('should get an accounts vesting time for a vesting entry index', async function() {
				const oneYearAhead = (await currentTime()) + DAY * 365;
				assert.isAtLeast(oneYearAhead, parseInt(await rewardEscrow.getVestingTime(account1, 0)));
				assert.isAtLeast(oneYearAhead, parseInt(await rewardEscrow.getVestingTime(account1, 1)));
				assert.isAtLeast(oneYearAhead, parseInt(await rewardEscrow.getVestingTime(account1, 2)));
			});

			it('should get an accounts vesting quantity for a vesting entry index', async function() {
				assert.bnEqual(await rewardEscrow.getVestingQuantity(account1, 0), toUnit('1000'));
				assert.bnEqual(await rewardEscrow.getVestingQuantity(account1, 1), toUnit('2000'));
				assert.bnEqual(await rewardEscrow.getVestingQuantity(account1, 2), toUnit('3000'));
			});
		});

		describe('Partial Vesting', async function() {
			beforeEach(async function() {
				// Transfer of SNX to the escrow must occur before creating a vestinng entry
				await synthetix.transfer(RewardEscrow.address, toUnit('6000'), { from: owner });

				// Add a few vesting entries as the feepool address
				await rewardEscrow.appendVestingEntry(account1, toUnit('1000'), { from: feePoolAccount });
				await fastForward(WEEK);
				await rewardEscrow.appendVestingEntry(account1, toUnit('2000'), { from: feePoolAccount });
				await fastForward(WEEK);
				await rewardEscrow.appendVestingEntry(account1, toUnit('3000'), { from: feePoolAccount });

				// fastForward to vest only the first weeks entry
				await fastForward(YEAR - WEEK * 2);

				// Update the rates as they will be stale now we're a year into the future
				await exchangeRates.updateRates([SNX], ['0.1'].map(toUnit), await currentTime(), {
					from: oracle,
				});

				// Vest
				await rewardEscrow.vest({ from: account1 });
			});

			it('should get an accounts next vesting entry index', async function() {
				assert.bnEqual(await rewardEscrow.getNextVestingIndex(account1), 1);
			});

			it('should get an accounts next vesting entry', async function() {
				let vestingScheduleEntry = await rewardEscrow.getNextVestingEntry(account1);
				assert.bnEqual(vestingScheduleEntry[1], toUnit('2000'));
			});

			it('should get an accounts next vesting time', async function() {
				const fiveDaysAhead = (await currentTime()) + DAY * 5;
				assert.isAtLeast(parseInt(await rewardEscrow.getNextVestingTime(account1)), fiveDaysAhead);
			});

			it('should get an accounts next vesting quantity', async function() {
				let nextVestingQuantity = await rewardEscrow.getNextVestingQuantity(account1);
				assert.bnEqual(nextVestingQuantity, toUnit('2000'));
			});
		});

		describe('Vesting', async function() {
			beforeEach(async function() {
				// Transfer of SNX to the escrow must occur before creating a vestinng entry
				await synthetix.transfer(RewardEscrow.address, toUnit('6000'), { from: owner });

				// Add a few vesting entries as the feepool address
				await rewardEscrow.appendVestingEntry(account1, toUnit('1000'), { from: feePoolAccount });
				await fastForward(WEEK);
				await rewardEscrow.appendVestingEntry(account1, toUnit('2000'), { from: feePoolAccount });
				await fastForward(WEEK);
				await rewardEscrow.appendVestingEntry(account1, toUnit('3000'), { from: feePoolAccount });

				// Need to go into the future to vest
				await fastForward(YEAR + WEEK * 3);

				// Update the rates as they will be stale now we're a year into the future
				await exchangeRates.updateRates([SNX], ['0.1'].map(toUnit), await currentTime(), {
					from: oracle,
				});
			});

			it('should vest and transfer snx from contract to the user', async function() {
				await rewardEscrow.vest({ from: account1 });

				// Check user has all their vested SNX
				assert.bnEqual(await synthetix.balanceOf(account1), toUnit('6000'));

				// Check rewardEscrow does not have any SNX
				assert.bnEqual(await synthetix.balanceOf(RewardEscrow.address), toUnit('0'));
			});

			it('should vest and emit a Vest event', async function() {
				const vestTransaction = await rewardEscrow.vest({ from: account1 });

				// Vested(msg.sender, now, total);
				const vestedEvent = vestTransaction.logs.find(log => log.event === 'Vested');
				assert.eventEqual(vestedEvent, 'Vested', {
					beneficiary: account1,
					value: toUnit('6000'),
				});
			});

			it('should vest and update totalEscrowedAccountBalance', async function() {
				// This account should have an escrowedAccountBalance
				let escrowedAccountBalance = await rewardEscrow.totalEscrowedAccountBalance(account1);
				assert.bnEqual(escrowedAccountBalance, toUnit('6000'));

				// Vest
				await rewardEscrow.vest({ from: account1 });

				// This account should not have any amount escrowed
				escrowedAccountBalance = await rewardEscrow.totalEscrowedAccountBalance(account1);
				assert.bnEqual(escrowedAccountBalance, toUnit('0'));
			});

			it('should vest and update totalVestedAccountBalance', async function() {
				// This account should have zero totalVestedAccountBalance
				let totalVestedAccountBalance = await rewardEscrow.totalVestedAccountBalance(account1);
				assert.bnEqual(totalVestedAccountBalance, toUnit('0'));

				// Vest
				await rewardEscrow.vest({ from: account1 });

				// This account should have vested its whole amount
				totalVestedAccountBalance = await rewardEscrow.totalVestedAccountBalance(account1);
				assert.bnEqual(totalVestedAccountBalance, toUnit('6000'));
			});

			it('should vest and update totalEscrowedBalance', async function() {
				await rewardEscrow.vest({ from: account1 });
				// There should be no Escrowed balance left in the contract
				assert.bnEqual(await rewardEscrow.totalEscrowedBalance(), toUnit('0'));
			});
		});

		describe('Stress Test', async function() {
			it('should be able to vest 52 week * 5 years vesting entries', async function() {
				// Transfer of SNX to the escrow must occur before creating an entry
				await synthetix.transfer(RewardEscrow.address, toUnit('260'), { from: owner });

				const MAX_VESTING_ENTRIES = 260; // await rewardEscrow.MAX_VESTING_ENTRIES();

				// Append the MAX_VESTING_ENTRIES to the schedule
				for (let i = 0; i < MAX_VESTING_ENTRIES; i++) {
					rewardEscrow.appendVestingEntry(account1, toUnit('1'), { from: feePoolAccount });
					await fastForward(SECOND);
				}

				// Need to go into the future to vest
				await fastForward(YEAR + DAY);

				// Update the rates as they will be stale now we're a year into the future
				await exchangeRates.updateRates([SNX], ['0.1'].map(toUnit), await currentTime(), {
					from: oracle,
				});

				// Vest
				await rewardEscrow.vest({ from: account1 });

				// Check user has all their vested SNX
				assert.bnEqual(await synthetix.balanceOf(account1), toUnit('260'));

				// Check rewardEscrow does not have any SNX
				assert.bnEqual(await synthetix.balanceOf(RewardEscrow.address), toUnit('0'));

				// This account should have vested its whole amount
				assert.bnEqual(await rewardEscrow.totalEscrowedAccountBalance(account1), toUnit('0'));

				// This account should have vested its whole amount
				assert.bnEqual(await rewardEscrow.totalVestedAccountBalance(account1), toUnit('260'));
			});
		});

		describe('Transfering', async function() {
			it('should not allow transfer of synthetix in escrow', async function() {
				// Ensure the transfer fails as all the synthetix are in escrow
				await assert.revert(synthetix.transfer(account2, toUnit('1000'), { from: account1 }));
			});
		});
	});
});
