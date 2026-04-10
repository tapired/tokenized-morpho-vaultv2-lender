// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";

interface IStrategyInterface is IStrategy {
    //TODO: Add your specific implementation interface in here.

    function setOpen(bool _open) external;
    function allowed(address _user) external view returns (bool);
    function setAllowed(address _user, bool _allowed) external;
}
