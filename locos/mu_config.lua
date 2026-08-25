-- mu_config.lua
-- Consist configuration - one copy per locomotive, and each copy is
-- THIS locomotive's own view of the consist.
--
-- Your own computer is identified by its label (`label set <name>` in
-- CC:Tweaked) and is NOT listed here. Only the OTHER locomotives are
-- listed, with their direction RELATIVE TO THIS locomotive:
--   reverse = true  : that locomotive faces opposite to this one
--   reverse = false : that locomotive faces the same way
--
-- No master/slave roles are stored here: the direction lever on each
-- vehicle selects its mode (0-4 forward = master, 5-10 neutral = slave,
-- 11-15 reverse = master). Exactly one master per protocol is required.

return {
    -- rednet protocol name: must be the same on every consist locomotive
    protocol = "loco-mu",

    -- Other locomotives in the consist, keyed by their computer label.
    -- Example view from a locomotive whose own label is LOCO-M1:
    others = {
        ["YL56U2_9002"] = { reverse = true  },  -- LOCO-S1 faces opposite to this loco
    },
}
