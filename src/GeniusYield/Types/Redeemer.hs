{-|
Module      : GeniusYield.Types.Redeemer
Copyright   : (c) 2023 GYELD GMBH
License     : Apache 2.0
Maintainer  : support@geniusyield.co
Stability   : develop

-}
module GeniusYield.Types.Redeemer (
    GYRedeemer,
    redeemerToApi,
    redeemerToPlutus,
    redeemerFromPlutus',
    redeemerFromPlutusData,
    unitRedeemer,
    nothingRedeemer,
) where

import qualified Cardano.Api         as Api
import qualified Cardano.Api.Shelley as Api
import           GeniusYield.Imports ((>>>))
import qualified PlutusLedgerApi.V1  as PlutusV1
import qualified PlutusTx

newtype GYRedeemer = GYRedeemer PlutusTx.BuiltinData
  deriving (Eq)

instance Show GYRedeemer where
    showsPrec d (GYRedeemer x) = showParen (d > 10)
        -- Show BuiltinData doesn't respect precedence.
        $ showString "redeemerFromPlutus' (BuiltinData ("
        . shows x
        . showString "))"

redeemerToPlutus :: GYRedeemer -> PlutusV1.Redeemer
redeemerToPlutus (GYRedeemer x) = PlutusV1.Redeemer x

redeemerToPlutus' :: GYRedeemer -> PlutusTx.BuiltinData
redeemerToPlutus' (GYRedeemer x) = x

redeemerFromPlutus' :: PlutusTx.BuiltinData -> GYRedeemer
redeemerFromPlutus' = GYRedeemer

redeemerFromPlutusData :: PlutusTx.ToData a => a -> GYRedeemer
redeemerFromPlutusData = GYRedeemer . PlutusTx.toBuiltinData

redeemerToApi :: GYRedeemer -> Api.HashableScriptData
redeemerToApi = redeemerToPlutus' >>> PlutusTx.builtinDataToData >>> Api.fromPlutusData >>> Api.unsafeHashableScriptData

-- | Unit redeemer
--
-- @'redeemerFromPlutusData' ()@.
--
-- Often used as an arbitrary redeemer.
--
unitRedeemer :: GYRedeemer
unitRedeemer = redeemerFromPlutusData ()

-- | A @'redeemerFromPlutusData' (Nothing \@a)@ for any @a@.
--
-- >>> nothingRedeemer
-- redeemerFromPlutus' (BuiltinData (Constr 1 []))
--
-- >>> redeemerFromPlutusData (Nothing @Integer)
-- redeemerFromPlutus' (BuiltinData (Constr 1 []))
--
nothingRedeemer :: GYRedeemer
nothingRedeemer = redeemerFromPlutusData (Nothing @())
