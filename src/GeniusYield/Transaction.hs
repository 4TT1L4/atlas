{-|
Module      : GeniusYield.Transaction
Description : Tools to build balanced transactions
Copyright   : (c) 2023 GYELD GMBH
License     : Apache 2.0
Maintainer  : support@geniusyield.co
Stability   : develop

Balancing algorithm.

Inputs:

    * Transaction inputs
    * Transaction outputs
    * Transaction minted value

Additionally:

    * Set of additional UTxOs which can be spent
    * Collateral UTxO
    * Change address

The algorithm should produce sets of inputs and outputs
such the total value is @input + minted = outputs@.

The algorithms used to select inputs & produce change outputs are defined in 'GeniusYield.Transaction.CoinSelection'.

Each output should be big enough
(contain enough ADA, 'Api.calculateMinimumUTxO').
Algorithm may adjust them to include additional value.

There are also transacton fees which should also be taken into account.
We over-approximate the fees, and let 'Api.makeTransactionBodyAutoBalance' balance fees.
(We can be more precise here, and only slightly over-approximate,
 but @cardano-api@ doesn't provide a handy helpers to fill in execution units).

We make the algorithm iterative over the fee over-approximation. In particular, we start off
with a small over-approximation, and if tx finalization fails, we increase it. The very first
success is returned. Any over approximation (above the actual required fees), leads to generation of change output (besides those generated by coin selection) by `Api.makeTransactionBodyAutoBalance`. This new change output may fail minimum ada requirement, in which case we iterate with increased fee approximate.

Collateral input is needed when scripts are executed,
i.e. transaction mints tokens or consumes script outputs.

See 'Api.evaluateTransactionBalance' and 'Api.makeTransactionBodyAutoBalance'
(this function balances ADA only and doesn't add inputs, i.e. it calculates the ADA change).

-}
module GeniusYield.Transaction (
    -- * Top level build interface
    GYBuildTxEnv (..),
    buildUnsignedTxBody,
    BuildTxException (..),
    GYCoinSelectionStrategy (..),
    -- * Balancing only
    balanceTxStep,
    finalizeGYBalancedTx,
    BalancingError (..),
    -- * Utility type
    GYTxInDetailed (..),
) where

import           Control.Monad.Trans.Except            (runExceptT, throwE)
import           Data.Foldable                         (for_)
import qualified Data.Map                              as Map
import           Data.Ratio                            ((%))

import           Data.Either.Combinators               (maybeToRight)
import           Data.Maybe                            (fromJust)

import qualified Cardano.Api                           as Api
import qualified Cardano.Api.Shelley                   as Api.S
import qualified Cardano.Ledger.Alonzo.Scripts         as AlonzoScripts
import qualified Cardano.Ledger.Alonzo.Tx              as AlonzoTx
import           Cardano.Slotting.Time                 (SystemStart)

import           Cardano.Ledger.Core                   (EraTx (sizeTxF))
import           Control.Lens                          (view)
import           Control.Monad.Random
import           GeniusYield.HTTP.Errors               (IsGYApiError)
import           GeniusYield.Imports
import           GeniusYield.Transaction.CBOR
import           GeniusYield.Transaction.CoinSelection
import           GeniusYield.Transaction.Common
import           GeniusYield.Types

-- | A container for various network parameters, and user wallet information, used by balancer.
data GYBuildTxEnv = GYBuildTxEnv
    { gyBTxEnvSystemStart    :: !SystemStart
    , gyBTxEnvEraHistory     :: !(Api.EraHistory Api.CardanoMode)
    , gyBTxEnvProtocolParams :: !(Api.S.BundledProtocolParameters Api.S.BabbageEra)
    , gyBTxEnvPools          :: !(Set Api.S.PoolId)
    , gyBTxEnvOwnUtxos       :: !GYUTxOs
    -- ^ own utxos available for use as additional input
    , gyBTxEnvChangeAddr     :: !GYAddress
    , gyBTxEnvCollateral     :: !GYUTxO
    }

utxoFromTxInDetailed :: GYTxInDetailed v -> GYUTxO
utxoFromTxInDetailed (GYTxInDetailed (GYTxIn ref _witns) addr val d ms) = GYUTxO ref addr val d ms

data BuildTxException
    = BuildTxBalancingError !BalancingError
    | BuildTxBodyErrorAutoBalance !Api.TxBodyErrorAutoBalance
    | BuildTxPPConversionError !Api.ProtocolParametersConversionError
    | BuildTxMissingMaxExUnitsParam
    -- ^ Missing max ex units in protocol params
    | BuildTxExUnitsTooBig  -- ^ Execution units required is higher than the maximum as specified by protocol params.
        (Natural, Natural)  -- ^ Tuple of maximum execution steps & memory as given by protocol parameters.
        (Natural, Natural)  -- ^ Tuple of execution steps & memory as taken by built transaction.

    | BuildTxSizeTooBig  -- ^ Transaction size is higher than the maximum as specified by protocol params.
        !Natural  -- ^ Maximum size as specified by protocol parameters.
        !Natural  -- ^ Size our built transaction took.
    | BuildTxCollateralShortFall  -- ^ Shortfall (in collateral inputs) for collateral requirement.
        !Natural  -- ^ Transaction collateral requirement.
        !Natural  -- ^ Lovelaces in given collateral UTxO.
    | BuildTxNoSuitableCollateral
    -- ^ Couldn't find a UTxO to use as collateral.
    | BuildTxCborSimplificationError !CborSimplificationError
  deriving stock    Show
  deriving anyclass (Exception, IsGYApiError)

-------------------------------------------------------------------------------
-- Top level wrappers around core balancing logic
-------------------------------------------------------------------------------

{- | This is the lovelace overshoot we start with; the balancer will try with bigger amounts if this one fails.

The overshoot is not only to cover fees, but also to cover min deposits for change output(s).
-}
extraLovelaceStart :: Natural
extraLovelaceStart = 1_000_000

{- | This is the extra lovelace ceiling, after which - random improve algo will no longer be tried.

Due to the way RandomImprove works, depending on wallet state - it may not be computationally efficient to use
it when the extraLovelace param has built up a lot. Falling back to largest first may be a better choice so as to not
time out.
-}
randImproveExtraLovelaceCeil :: Natural
randImproveExtraLovelaceCeil = 20_000_000

-- | Pure interface to build the transaction body given necessary information.
buildUnsignedTxBody :: forall m v.
           (HasCallStack, MonadRandom m)
        => GYBuildTxEnv
        -> GYCoinSelectionStrategy
        -> [GYTxInDetailed v]
        -> [GYTxOut v]
        -> GYUTxOs  -- ^ reference inputs
        -> Maybe (GYValue, [(GYMintScript v, GYRedeemer)])  -- ^ minted values
        -> Maybe GYSlot
        -> Maybe GYSlot
        -> Set GYPubKeyHash
        -> m (Either BuildTxException GYTxBody)
buildUnsignedTxBody env cstrat insOld outsOld refIns mmint lb ub signers = buildTxLoop cstrat extraLovelaceStart
  where

    step :: GYCoinSelectionStrategy -> Natural -> m (Either BuildTxException ([GYTxInDetailed v], GYUTxOs, [GYTxOut v]))
    step stepStrat = fmap (first BuildTxBalancingError) . balanceTxStep env mmint insOld outsOld stepStrat

    buildTxLoop :: GYCoinSelectionStrategy -> Natural -> m (Either BuildTxException GYTxBody)
    buildTxLoop stepStrat n
        -- Stop trying with RandomImprove if extra lovelace has hit the pre-determined ceiling.
        | stepStrat /= GYLargestFirstMultiAsset && n >= randImproveExtraLovelaceCeil = buildTxLoop GYLargestFirstMultiAsset n
        | otherwise = do
            res <- f stepStrat n
            case res of
                {- These errors generally indicate the input selection process selected less ada
                than necessary. Try again with double the extra lovelace amount -}
                Left (BuildTxBodyErrorAutoBalance Api.TxBodyErrorAdaBalanceNegative{}) -> buildTxLoop stepStrat (n * 2)
                Left (BuildTxBodyErrorAutoBalance Api.TxBodyErrorAdaBalanceTooSmall{}) -> buildTxLoop stepStrat (n * 2)
                -- @RandomImprove@ may result into many change outputs, where their minimum ada requirements might be unsatisfiable with available ada.
                Left (BuildTxBalancingError err@(BalancingErrorChangeShortFall _))         -> retryIfRandomImprove
                                                                                            stepStrat
                                                                                            n
                                                                                            (BuildTxBalancingError err)
                {- RandomImprove may end up selecting too many inputs to fit in the transaction.
                In this case, try with LargestFirst and dial back the extraLovelace param.
                -}
                Left (BuildTxExUnitsTooBig maxUnits currentUnits)                      -> retryIfRandomImprove
                                                                                            stepStrat
                                                                                            n
                                                                                            (BuildTxExUnitsTooBig maxUnits currentUnits)
                Left (BuildTxSizeTooBig maxPossibleSize currentSize)                   -> retryIfRandomImprove
                                                                                            stepStrat
                                                                                            n
                                                                                            (BuildTxSizeTooBig maxPossibleSize currentSize)
                Right x                                                                -> pure $ Right x
                {- The most common error here would be:
                - InsufficientFunds
                - Script validation failure
                - Tx not within validity range specified timeframe

                No need to try again for these.
                -}
                other                                                                  -> pure other

    f :: GYCoinSelectionStrategy -> Natural -> m (Either BuildTxException GYTxBody)
    f stepStrat pessimisticFee = do
        stepRes <- step stepStrat pessimisticFee
        pure $ stepRes >>= \(ins, collaterals, outs) ->
            finalizeGYBalancedTx
                env
                GYBalancedTx
                    { gybtxIns           = ins
                    , gybtxCollaterals   = collaterals
                    , gybtxOuts          = outs
                    , gybtxMint          = mmint
                    , gybtxInvalidBefore = lb
                    , gybtxInvalidAfter  = ub
                    , gybtxSigners       = signers
                    , gybtxRefIns        = refIns
                    }

    retryIfRandomImprove GYRandomImproveMultiAsset n _ = buildTxLoop GYLargestFirstMultiAsset (if n == extraLovelaceStart then extraLovelaceStart else n `div` 2)
    retryIfRandomImprove _ _ err                       = pure $ Left err

-------------------------------------------------------------------------------
-- Primary balancing logic
-------------------------------------------------------------------------------

{- | An independent "step" of the balancing algorithm.

This step is meant to be run with different 'extraLovelace' values. If the 'extraLovelace' amount
is too small, there will not be enough ada to pay for the final fees + min deposits, when finalizing
the tx with 'finalizeGYBalancedTx'. If such is the case, 'balanceTxStep' should be called again with a higher
'extraLovelace' amount.
-}
balanceTxStep :: (HasCallStack, MonadRandom m)
    => GYBuildTxEnv
    -> Maybe (GYValue, [(GYMintScript v, GYRedeemer)])  -- ^ minting
    -> [GYTxInDetailed v]                               -- ^ transaction inputs
    -> [GYTxOut v]                                      -- ^ transaction outputs
    -> GYCoinSelectionStrategy                          -- ^ Coin selection strategy to use
    -> Natural                                          -- ^ extra lovelace to look for on top of output value
    -> m (Either BalancingError ([GYTxInDetailed v], GYUTxOs, [GYTxOut v]))
balanceTxStep
    GYBuildTxEnv
        { gyBTxEnvProtocolParams = pp
        , gyBTxEnvOwnUtxos       = ownUtxos
        , gyBTxEnvChangeAddr     = changeAddr
        , gyBTxEnvCollateral     = collateral
        }
    mmint
    ins
    outs
    cstrat
    = let adjustedOuts = map (adjustTxOut (minimumUTxO pp)) outs
          valueMint       = maybe mempty fst mmint
          needsCollateral = valueMint /= mempty || any (isScriptWitness . gyTxInWitness . gyTxInDet) ins
          collaterals
            | needsCollateral = utxosFromUTxO collateral
            | otherwise       = mempty
      in \extraLovelace -> runExceptT $ do
            for_ adjustedOuts $ \txOut ->
                unless (valueNonNegative $ gyTxOutValue txOut)
                    . throwE $ BalancingErrorNonPositiveTxOut txOut
            (addIns, changeOuts) <- selectInputs
                GYCoinSelectionEnv
                    { existingInputs  = ins
                    , requiredOutputs = (\out -> (gyTxOutAddress out, gyTxOutValue out)) <$> adjustedOuts
                    , mintValue       = valueMint
                    , changeAddr      = changeAddr
                    , ownUtxos        = ownUtxos
                    , extraLovelace   = extraLovelace
                    , minimumUTxOF    =
                        fromInteger
                        . flip valueAssetClass GYLovelace
                          . gyTxOutValue
                            . adjustTxOut (minimumUTxO pp)
                    , maxValueSize    = fromMaybe
                                            (error "protocolParamMaxValueSize missing from protocol params")
                                            $ Api.S.protocolParamMaxValueSize $ Api.S.unbundleProtocolParams pp
                    }
                cstrat
            pure (ins ++ addIns, collaterals, adjustedOuts ++ changeOuts)
  where
    isScriptWitness GYTxInWitnessKey      = False
    isScriptWitness GYTxInWitnessScript{} = True

retColSup :: Api.S.TxTotalAndReturnCollateralSupportedInEra Api.S.BabbageEra
retColSup = Api.TxTotalAndReturnCollateralInBabbageEra

finalizeGYBalancedTx :: GYBuildTxEnv -> GYBalancedTx v -> Either BuildTxException GYTxBody
finalizeGYBalancedTx
    GYBuildTxEnv
        { gyBTxEnvSystemStart    = ss
        , gyBTxEnvEraHistory     = eh
        , gyBTxEnvProtocolParams = pp
        , gyBTxEnvPools          = ps
        , gyBTxEnvChangeAddr     = changeAddr
        }
    GYBalancedTx
        { gybtxIns           = ins
        , gybtxCollaterals   = collaterals
        , gybtxOuts          = outs
        , gybtxMint          = mmint
        , gybtxInvalidBefore = lb
        , gybtxInvalidAfter  = ub
        , gybtxSigners       = signers
        , gybtxRefIns        = utxosRefInputs
        }
    = makeTransactionBodyAutoBalanceWrapper
        collaterals
        ss
        eh
        pp
        ps
        (utxosToApi utxos)
        body
        changeAddr
  where

    inRefs :: Api.TxInsReference Api.BuildTx Api.BabbageEra
    inRefs = case inRefs' of
        [] -> Api.TxInsReferenceNone
        _  -> Api.TxInsReference Api.S.ReferenceTxInsScriptsInlineDatumsInBabbageEra inRefs'

    inRefs' :: [Api.TxIn]
    inRefs' = [ txOutRefToApi r | r <- utxosRefs utxosRefInputs ]

    -- utxos for inputs
    utxosIn :: GYUTxOs
    utxosIn = utxosFromList $ utxoFromTxInDetailed <$> ins

    -- Map to lookup information for various utxos.
    utxos :: GYUTxOs
    utxos = utxosIn <> utxosRefInputs <> collaterals

    outs' :: [Api.S.TxOut Api.S.CtxTx Api.S.BabbageEra]
    outs' = txOutToApi <$> outs

    ins' :: [(Api.TxIn, Api.BuildTxWith Api.BuildTx (Api.Witness Api.WitCtxTxIn Api.BabbageEra))]
    ins' = [ txInToApi (isInlineDatum $ gyTxInDetDatum i) (gyTxInDet i) |  i <- ins ]

    collaterals' :: Api.TxInsCollateral Api.BabbageEra
    collaterals' = case utxosRefs collaterals of
        []    -> Api.TxInsCollateralNone
        orefs -> Api.TxInsCollateral Api.CollateralInBabbageEra $ txOutRefToApi <$> orefs

    -- will be filled by makeTransactionBodyAutoBalance
    fee :: Api.TxFee Api.BabbageEra
    fee = Api.TxFeeExplicit Api.TxFeesExplicitInBabbageEra $ Api.Lovelace 0

    lb' :: Api.TxValidityLowerBound Api.BabbageEra
    lb' = maybe
        Api.TxValidityNoLowerBound
        (Api.TxValidityLowerBound Api.ValidityLowerBoundInBabbageEra . slotToApi)
        lb

    ub' :: Api.TxValidityUpperBound Api.BabbageEra
    ub' = maybe
        (Api.TxValidityNoUpperBound Api.ValidityNoUpperBoundInBabbageEra)
        (Api.TxValidityUpperBound Api.ValidityUpperBoundInBabbageEra . slotToApi)
        ub

    extra :: Api.TxExtraKeyWitnesses Api.BabbageEra
    extra = case toList signers of
        []   -> Api.TxExtraKeyWitnessesNone
        pkhs -> Api.TxExtraKeyWitnesses Api.ExtraKeyWitnessesInBabbageEra $ pubKeyHashToApi <$> pkhs

    mint :: Api.TxMintValue Api.BuildTx Api.BabbageEra
    mint = case mmint of
        Nothing      -> Api.TxMintNone
        Just (v, xs) -> Api.TxMintValue Api.MultiAssetInBabbageEra (valueToApi v) $ Api.BuildTxWith $ Map.fromList
            [ ( mintingPolicyApiIdFromWitness p
              , gyMintingScriptWitnessToApiPlutusSW p
                      (redeemerToApi r)
                      (Api.ExecutionUnits 0 0)
              )
            | (p, r) <- xs
            ]

    -- Putting `TxTotalCollateralNone` & `TxReturnCollateralNone` would have them appropriately calculated by `makeTransactionBodyAutoBalance` but then return collateral it generates is only for ada. To support multi-asset collateral input we therefore calculate correct values ourselves and put appropriate entries here to have `makeTransactionBodyAutoBalance` calculate appropriate overestimated fees.
    (dummyTotCol :: Api.TxTotalCollateral Api.BabbageEra, dummyRetCol :: Api.TxReturnCollateral Api.CtxTx Api.BabbageEra) =
      if mempty == collaterals then
        (Api.TxTotalCollateralNone, Api.TxReturnCollateralNone)
      else
        (
        -- Total collateral must be <= lovelaces available in collateral inputs.
          Api.TxTotalCollateral retColSup (Api.Lovelace $ fst $ valueSplitAda collateralTotalValue)
        -- Return collateral must be <= what is in collateral inputs.
        , Api.TxReturnCollateral retColSup $ txOutToApi $ GYTxOut changeAddr collateralTotalValue Nothing Nothing
        )
      where
        collateralTotalValue :: GYValue
        collateralTotalValue = foldMapUTxOs utxoValue collaterals

    body :: Api.TxBodyContent Api.BuildTx Api.BabbageEra
    body = Api.TxBodyContent
        ins'
        collaterals'
        inRefs
        outs'
        dummyTotCol
        dummyRetCol
        fee
        (lb', ub')
        Api.TxMetadataNone
        Api.TxAuxScriptsNone
        extra
        (Api.BuildTxWith $ Just $ Api.S.unbundleProtocolParams pp)
        Api.TxWithdrawalsNone
        Api.TxCertificatesNone
        Api.TxUpdateProposalNone
        mint
        Api.TxScriptValidityNone

{- | Wraps around 'Api.makeTransactionBodyAutoBalance' just to verify the final ex units and tx size are within limits.

If not checked, the returned txbody may fail during submission.
-}
makeTransactionBodyAutoBalanceWrapper :: GYUTxOs
                                      -> SystemStart
                                      -> Api.S.EraHistory Api.S.CardanoMode
                                      -> Api.S.BundledProtocolParameters Api.S.BabbageEra
                                      -> Set Api.S.PoolId
                                      -> Api.S.UTxO Api.S.BabbageEra
                                      -> Api.S.TxBodyContent Api.S.BuildTx Api.S.BabbageEra
                                      -> GYAddress
                                      -> Either BuildTxException GYTxBody
makeTransactionBodyAutoBalanceWrapper collaterals ss eh pp ps utxos body changeAddr = do
    Api.ExecutionUnits
        { executionSteps  = maxSteps
        , executionMemory = maxMemory
        } <- maybeToRight BuildTxMissingMaxExUnitsParam $ Api.S.protocolParamMaxTxExUnits $ Api.S.unbundleProtocolParams pp
    let maxTxSize = Api.S.protocolParamMaxTxSize $ Api.S.unbundleProtocolParams pp
        changeAddrApi :: Api.S.AddressInEra Api.S.BabbageEra = addressToApi' changeAddr
        stakeDelegDeposits = mempty  -- TODO: Currently it's empty as we don't support for unregistration!

    -- First we obtain the calculated fees to correct for our collaterals.
    bodyBeforeCollUpdate@(Api.BalancedTxBody _ _ _ (Api.Lovelace feeOld)) <-
      first BuildTxBodyErrorAutoBalance $ Api.makeTransactionBodyAutoBalance
        ss
        (Api.toLedgerEpochInfo eh)
        (Api.S.unbundleProtocolParams pp)
        ps
        stakeDelegDeposits
        utxos
        body
        changeAddrApi
        Nothing

    -- We should call `makeTransactionBodyAutoBalance` again with updated values of collaterals so as to get slightly lower fee estimate.
    Api.BalancedTxBody _ txBody _ _ <- if collaterals == mempty then return bodyBeforeCollUpdate else

      let

        collateralTotalValue :: GYValue = foldMapUTxOs utxoValue collaterals
        collateralTotalLovelace :: Integer = fst $ valueSplitAda collateralTotalValue
        balanceNeeded :: Integer = ceiling $ (feeOld * toInteger (fromJust $ Api.S.protocolParamCollateralPercent $ Api.S.unbundleProtocolParams pp)) % 100

      in do

        (txColl, collRet) <-
          if collateralTotalLovelace >= balanceNeeded then return
            (
              Api.TxTotalCollateral retColSup (Api.Lovelace balanceNeeded)
            , Api.TxReturnCollateral retColSup $ txOutToApi $ GYTxOut changeAddr (collateralTotalValue `valueMinus` valueFromLovelace balanceNeeded) Nothing Nothing

            )
          else Left $ BuildTxCollateralShortFall (fromInteger balanceNeeded) (fromInteger collateralTotalLovelace) -- In this case `makeTransactionBodyAutoBalance` doesn't return an error but instead returns `(Api.TxTotalCollateralNone, Api.TxReturnCollateralNone)`

        first BuildTxBodyErrorAutoBalance $ Api.makeTransactionBodyAutoBalance
          ss
          (Api.toLedgerEpochInfo eh)
          (Api.S.unbundleProtocolParams pp)
          ps
          stakeDelegDeposits
          utxos
          body {Api.txTotalCollateral = txColl, Api.txReturnCollateral = collRet}
          changeAddrApi
          Nothing

    let Api.S.ShelleyTx _ ltx = Api.Tx txBody []
        -- This sums up the ExUnits for all embedded Plutus Scripts anywhere in the transaction:
        AlonzoScripts.ExUnits
            { AlonzoScripts.exUnitsSteps = steps
            , AlonzoScripts.exUnitsMem   = mem
            } = AlonzoTx.totExUnits ltx
        txSize :: Natural = fromInteger $ view sizeTxF ltx
    -- See: Cardano.Ledger.Alonzo.Rules.validateExUnitsTooBigUTxO
    unless (steps <= maxSteps && mem <= maxMemory) $
        Left $ BuildTxExUnitsTooBig (maxSteps, maxMemory) (steps, mem)
    -- See: Cardano.Ledger.Shelley.Rules.validateMaxTxSizeUTxO
    unless (txSize <= maxTxSize) $
        {- Technically, this doesn't compare with the _final_ tx size, because of signers that will be
        added later. But signing witnesses are only a few bytes, so it's unlikely to be an issue -}
        Left (BuildTxSizeTooBig maxTxSize txSize)
    first BuildTxCborSimplificationError $ simplifyGYTxBodyCbor $ txBodyFromApi txBody
