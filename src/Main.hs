module Main where

import           Data.Aeson ( FromJSON(parseJSON), ToJSON(toJSON), Value(Object)
                            , object, withText
                            , (.:), (.=)
                            )
import qualified Data.Aeson             as Aeson
import qualified Data.Aeson.Types       as Aeson
import qualified Data.ByteString        as BS
import qualified Data.ByteString.Lazy   as BL ( toStrict )
import qualified Data.ByteString.UTF8   as BSU
import qualified Data.ByteString.Base16 as Base16
import qualified Data.String            as S
import qualified Data.Text              as T
import           Data.Time ( UTCTime )
import           GHC.Generics ( Generic )
import           Network.Wai ( Application
                             , Request
                             , Response
                             , pathInfo
                             , consumeRequestBodyStrict
                             , requestMethod
                             , responseStatus
                             , rawPathInfo
                             , responseLBS
                             , responseBuilder
                             )
import           Network.HTTP.Types ( status200, status405, status406
                                    , hContentType
                                    )
import           Network.Wai.Handler.Warp ( run )

import           Language.Marlowe.Core.V1.Semantics hiding (applyAction)
import           Language.Marlowe.Core.V1.Semantics.Types
import           Language.Marlowe.Scripts.Types ( MarloweInput
                                                , marloweTxInputsFromInputs
                                                )
import           Language.Marlowe.Runtime.Web

import           Plutus.V1.Ledger.SlotConfig ( utcTimeToPOSIXTime )
import           PlutusTx ( ToData(..), FromData (..)
                          , dataToBuiltinData
                          , builtinDataToData
                          )
import qualified Cardano.Api.Shelley as Shelley

data ApplyRequest = ApplyRequest
                    { version          :: MarloweVersion
                    , marloweData      :: MarloweData
                    , invalidBefore    :: UTCTime
                    , invalidHereafter :: UTCTime
                    , inputs           :: [Input]
                    }
    deriving stock (Show, Generic)

type ApplyResponse = Either ApplyError (MarloweData, MarloweInput, [Payment])

data ApplyError = NonChoiceInputs [Input]
                | ComputeTransactionError TransactionError

main :: IO ()
main = do
    let port = 3000

    putStrLn $ unwords ["Starting budget-service at port:", show port]
    putStrLn "Quit the service with CONTROL-C."
    run port marloweApplyApp

marloweApplyApp :: Application
marloweApplyApp req send =
    case pathInfo req of
        ["apply"] -> applyAction req
        _         -> pure badRequest
    >>= send

applyAction :: Request -> IO Response
applyAction req = do
    logRequest req
    case requestMethod req of
        "POST" -> do
            body <- BL.toStrict <$> consumeRequestBodyStrict req
            print body

            applyReq <- decodeApplyReq body

            generateResponse $ computeNewMarloweData applyReq

        _otherMethod -> do
            putStrLn $ unwords [ "Bad Request Error status:"
                               , show $ responseStatus badRequest
                               ]
            pure badRequest

computeNewMarloweData :: ApplyRequest -> ApplyResponse
computeNewMarloweData ApplyRequest{ marloweData
                                  , invalidBefore, invalidHereafter
                                  , inputs
                                  } | onlyChoiceInputs inputs =
    case mOutput of
        TransactionOutput{txOutState, txOutContract, txOutPayments} ->
            Right ( mkDatum txOutState txOutContract
                  , marloweTxInputsFromInputs inputs
                  , txOutPayments
                  )
        Error txError ->
            Left $ ComputeTransactionError txError

  where
    mkDatum :: State -> Contract -> MarloweData
    mkDatum newState newContract =  MarloweData
                                    { marloweParams   = marloweParams marloweData
                                    , marloweState    = newState
                                    , marloweContract = newContract
                                    }

    mOutput :: TransactionOutput
    mOutput = computeTransaction
              (TransactionInput { txInterval = mdTimeInterval
                                , txInputs = inputs
                                }
              )
              (marloweState marloweData)
              (marloweContract marloweData)

    mdTimeInterval :: TimeInterval
    mdTimeInterval =
        -- Because some Marlowe validations we must round up the millisecond part
        -- (last three digits).
        ( (utcTimeToPOSIXTime invalidBefore `div` 1000) * 1000
        , utcTimeToPOSIXTime invalidHereafter
        )

computeNewMarloweData ApplyRequest{ inputs } = Left $ NonChoiceInputs inputs

onlyChoiceInputs :: [Input] -> Bool
onlyChoiceInputs = all isChoice
    where
      isChoice :: Input -> Bool
      isChoice (NormalInput (IChoice _ _)) = True
      isChoice (MerkleizedInput (IChoice _ _) _ _) = True
      isChoice _ = False

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

generateResponse :: ApplyResponse -> IO Response
generateResponse (Right (md, rdr, pays)) =
    pure
    $ responseLBS status200 [ (hContentType, "application/json") ]
    $ Aeson.encode $ object [ "datumCborHex" .= builtinDataToString md
                            , "redeemerCborHex" .= builtinDataToString rdr
                            , "payments" .= pays
                            ]
generateResponse (Left err) = pure
    $ responseLBS status406 [ (hContentType, "application/json") ]
    $ Aeson.encode err

readMarloweData :: Aeson.Value -> Aeson.Parser MarloweData
readMarloweData = withText "readMarloweData" $ \text ->
    case Base16.decode $ S.fromString $ T.unpack text of
        Left err -> fail (show err)
        Right dec ->
            case Shelley.deserialiseFromCBOR Shelley.AsScriptData dec of
                Left err -> fail (show err)
                Right dec -> maybe (fail "Decoding Data") return $ decodeData dec
  where
    decodeData :: Shelley.ScriptData -> Maybe MarloweData
    decodeData = PlutusTx.fromBuiltinData
                 . PlutusTx.dataToBuiltinData
                 . Shelley.toPlutusData

builtinDataToString :: ToData a => a -> String
builtinDataToString = BSU.toString
                      . Base16.encode
                      . Shelley.serialiseToCBOR
                      . Shelley.fromPlutusData
                      . PlutusTx.builtinDataToData
                      . PlutusTx.toBuiltinData

decodeApplyReq :: BS.ByteString -> IO ApplyRequest
decodeApplyReq body =
    case Aeson.eitherDecodeStrict body of
        Left err -> error $ "decodeReq error: " ++ err
        Right ptr -> return ptr

logRequest :: Request -> IO ()
logRequest req = do
    putStrLn $ unwords ["Request method:", show $ requestMethod req ]
    putStrLn $ unwords ["Request path:", show $ rawPathInfo req ]

badRequest :: Response
badRequest = responseBuilder status405 [] "Bad request method"

instance ToJSON ApplyError where
    toJSON (NonChoiceInputs message) = Aeson.object ["error" .= message]
    toJSON (ComputeTransactionError txError) = Aeson.object ["error" .= txError]

instance FromJSON ApplyRequest where
    parseJSON (Object obj) = ApplyRequest
        <$> obj .: "version"
        <*> (readMarloweData =<< obj .: "marloweData")
        <*> obj .:  "invalidBefore"
        <*> obj .:  "invalidHereafter"
        <*> obj .:  "inputs"

    parseJSON _ = fail "Expecting object value"
