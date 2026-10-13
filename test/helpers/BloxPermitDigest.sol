// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Independent EIP-712/EIP-2612 encoding: never ask the token for its domain or nonce.
library BloxPermitDigest {
    function domain(address token, uint256 chainId) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Blox"),
                keccak256("1"),
                chainId,
                token
            )
        );
    }

    function digest(
        address token,
        uint256 chainId,
        address owner,
        address spender,
        uint256 value,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (bytes32) {
        bytes32 permitHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                spender,
                value,
                nonce,
                deadline
            )
        );
        return keccak256(abi.encodePacked(hex"1901", domain(token, chainId), permitHash));
    }
}
