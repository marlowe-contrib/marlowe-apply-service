# Marlowe Apply Service

Build the Marlowe datum, redeemer, and payment information result of applying **only** choice inputs to an open Marlowe contract. Similar to the [`applyInputsToContract`](https://docs.marlowe.iohk.io/api/apply-inputs-to-contract) but only responding with the necessary information to build your own balanced transaction.

## Building and Running

``` bash
$> docker build -t marlowe-apply .
$> docker run -p 3000:3000 -it marlowe-apply
```

## Usage

There is only one endpoint available in the service, which is called `apply`.

```bash
$> curl localhost:3000/apply -d @request.json
```

The request must contain the complete `marloweData`, that is, the complete datum of the UTxO, in cbor-hex encoding, together with a list of `inputs` to apply in JSON format. Besides that, we also need to include the `invalidaBefore` and `invalidHereafter` times in UTC format.

```json
{
  "version": "v1",
  "marloweData": "d8799fd8799f581cbcda83498f8d953a9f6bf43c269dd44c5bd8e5b892429d3e9da00c68ffd8799fa2d8799fd8799fd87980d8799fd8799f581cb80600589f0850ec775409e5cb98e276175ce814202f3350c4df97d5ffd87a80ffffd8799f4040ffff1a001e8480d8799fd8799fd87980d8799fd8799f581cb80600589f0850ec775409e5cb98e276175ce814202f3350c4df97d5ffd87a80ffffd8799f581cbcda83498f8d953a9f6bf43c269dd44c5bd8e5b892429d3e9da00c684c54687265616420546f6b656effff01a0a000ffd87c9f9fd8799fd87a9fd8799f4e436861726c693320414441555344d87a9f4e436861726c6933204f7261636c65ffff9fd8799f18641b000000174876e800ffffffd87c9f9fd8799fd87b9fd9050280ffd87980ffff1b0000018dbdec788ad87980ffffff1b0000018dbdec788ad87980ffff",
  "invalidBefore": "2024-01-18T20:37:41.123Z",
  "invalidHereafter": "2024-02-18T06:42:41.733Z",
  "inputs": [
    {
      "for_choice_id": {
        "choice_name": "Charli3 ADAUSD",
        "choice_owner": {
            "role_token": "Charli3 Oracle"
        }
      },
      "input_that_chooses_num": 501894
    }
  ]
}
```
This request can be found in [`request.json`](./request.json) example.

A successful response has three parts. The new datum in `datumCborHex` is the result of applying the given inputs. The redeemer in `redeemerCborHex`, that must be applied to the current Marlowe contract and a list of payments.

```json
{
  "datumCborHex": "d8799fd8799f581cbcda83498f8d953a9f6bf43c269dd44c5bd8e5b892429d3e9da00c68ffd8799fa2d8799fd8799fd87980d8799fd8799f581cb80600589f0850ec775409e5cb98e276175ce814202f3350c4df97d5ffd87a80ffffd8799f4040ffff1a001e8480d8799fd8799fd87980d8799fd8799f581cb80600589f0850ec775409e5cb98e276175ce814202f3350c4df97d5ffd87a80ffffd8799f581cbcda83498f8d953a9f6bf43c269dd44c5bd8e5b892429d3e9da00c684c54687265616420546f6b656effff01a1d8799f4e436861726c693320414441555344d87a9f4e436861726c6933204f7261636c65ffff1a0007a886a01b0000018d1e4b3208ffd87c9f9fd8799fd87b9fd9050280ffd87980ffff1b0000018dbdec788ad87980ffff",
  "payments": [],
  "redeemerCborHex": "9fd8799fd87a9fd8799f4e436861726c693320414441555344d87a9f4e436861726c6933204f7261636c65ffff1a0007a886ffffff"
}
```

A non-successful response will have this format `{ "error": ERROR }`, where `ERROR` can be any of:
- NonChoiceInputs: The service only support applying choice inputs.
- ComputeTransactionError [error](https://github.com/input-output-hk/marlowe-cardano/blob/db25114ec91ccdab3228b99e791fd7232f8625bf/marlowe/src/Language/Marlowe/Core/V1/Semantics.hs#L311-L316)https://github.com/input-output-hk/marlowe-cardano/blob/db25114ec91ccdab3228b99e791fd7232f8625bf/marlowe/src/Language/Marlowe/Core/V1/Semantics.hs#L311-L316: Some internal error result of applying the given inputs.
