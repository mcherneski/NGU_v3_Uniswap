# Hook Minting Ideas

1. Use the delta from Uniswap
   - Round whole number delta
   - Potentially misses glyphs
2. Mint the glyph difference after settling the balance
   - Add the delta (+ or -) to the current ERC20 balance, subtract new glyphs from old glyphs.