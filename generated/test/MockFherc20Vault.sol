// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { FHE, externalEuint64, euint64 } from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import { FHERC20 } from "../FHERC20/FHERC20.sol";
import { FHESafeMath } from "../utils/FHESafeMath.sol";

contract MockFHERC20Vault {
    FHERC20 public immutable asset;
    mapping(address => euint64) public balances;

    constructor(address _asset) {
        require(_asset != address(0), "Invalid asset");
        asset = FHERC20(_asset);
    }

    function deposit(externalEuint64 inAmount_input, bytes memory inputProof) external {
        euint64 inAmount = FHE.asEuint64(inAmount_input, inputProof);
        euint64 transferred = FHE.receiveEuint64FromCall(
            asset.confidentialTransferFrom(msg.sender, address(this), FHE.shareEuint64(inAmount, address(asset))),
            address(asset)
        );
        (, euint64 updated) = FHESafeMath.tryAdd(balances[msg.sender], transferred);
        balances[msg.sender] = updated;
    }
}
