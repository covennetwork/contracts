// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
import {CovenSession} from "./CovenSession.sol";
contract CovenSessionFactory {
    address public immutable ROUTER;
    address public immutable LENS;
    mapping(address session => bool created) public isSession;
    mapping(address owner => address[] sessions) private _ownerSessions;
    error InvalidRouterLens();
    event SessionCreated(address indexed owner, address indexed session, bytes32 salt);
    constructor(address router, address lens) {
        if (router.code.length == 0 || lens.code.length == 0) revert InvalidRouterLens();
        ROUTER = router;
        LENS = lens;
    }
    function create(CovenSession.InitConfig memory cfg, bytes32 salt) external returns (address session) {
        address owner = msg.sender;
        cfg.router = ROUTER;
        cfg.lens = LENS;
        bytes32 create2Salt = keccak256(abi.encode(owner, salt));
        session = address(new CovenSession{salt: create2Salt}(owner, cfg));
        isSession[session] = true;
        _ownerSessions[owner].push(session);
        emit SessionCreated(owner, session, salt);
    }
    function predict(address owner, CovenSession.InitConfig memory cfg, bytes32 salt) external view returns (address) {
        cfg.router = ROUTER;
        cfg.lens = LENS;
        bytes32 create2Salt = keccak256(abi.encode(owner, salt));
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(CovenSession).creationCode, abi.encode(owner, cfg)));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), create2Salt, initCodeHash)))));
    }
    function sessionsOf(address owner) external view returns (address[] memory) {
        return _ownerSessions[owner];
    }
}
