// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/**
 * @title Prng
 * @notice Deterministic pseudo-random source for the simulation.
 *
 * @dev A keccak chain seeded by a fixed constant and consumed strictly in order. Nothing
 *      from the block is mixed in, so a run is reproducible byte for byte: a failure found
 *      on CI reproduces locally, and a fix can be shown to address that exact sequence.
 *
 *      Equivalent to materialising tens of thousands of numbers up front and reading them
 *      off in order, without paying to store them.
 */
library Prng {
    struct State {
        uint256 value;
    }

    function next(State storage s) internal returns (uint256) {
        uint256 v = uint256(keccak256(abi.encodePacked(s.value)));
        s.value = v;
        return v;
    }

    /// @notice Uniform in [min, max]. `max` must not be below `min`.
    function range(State storage s, uint256 min, uint256 max) internal returns (uint256) {
        if (max <= min) return min;
        return min + (next(s) % (max - min + 1));
    }

    /**
     * @notice Log-uniform in [min, max].
     * @dev Uniform sampling of an amount between 1 wei and thousands of tokens would spend
     *      essentially every draw at the top of the range and never exercise dust. Sampling
     *      the magnitude first gives the small end real coverage.
     */
    function magnitude(State storage s, uint256 min, uint256 max) internal returns (uint256) {
        if (max <= min) return min;
        uint256 span = max - min;
        uint256 bits = 0;
        while (span >> bits > 0 && bits < 255) {
            bits++;
        }
        uint256 chosenBits = range(s, 0, bits);
        uint256 mask = chosenBits == 0 ? 0 : (1 << chosenBits) - 1;
        uint256 sample = next(s) & mask;
        return sample > span ? max : min + sample;
    }

    function chance(State storage s, uint256 percent) internal returns (bool) {
        return next(s) % 100 < percent;
    }
}
