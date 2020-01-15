pragma solidity ^0.5.12;

import "../node_modules/openzeppelin-solidity/contracts/token/ERC721/ERC721Full.sol";

contract AsyncArtwork is ERC721Full {
    // An event whenever the platform address is updated
    event PlatformAddressUpdated (
        address platformAddress
    );

    // An event whenever royalty amounts are updated
    event RoyaltyAmountUpdated (
        uint256 newPlatformFirstSaleRoyaltyPercentage,
        uint256 newPlatformSecondaryRoyaltyPercentage,
        uint256 newArtistSecondaryRoyaltyPercentage
    );

    event ControlTokenConfirmed (
        uint256 controlTokenId
    );

    event ArtworkConfirmed (
        uint256 artworkTokenId
    );

	// An event whenever a bid is proposed
	event BidProposed (		
		address bidder,
		uint256 tokenId,
        uint256 bidAmount
    );

	// An event whenever an bid is withdrawn
    event BidWithdrawn (
    	address bidder,
    	uint256 tokenId
    );

    // An event whenever a buy now price has been set
    event BuyPriceSet (
    	uint256 tokenId,
    	uint256 price
    );

    // An event when a token has been sold 
    event TokenSale (
    	// the address of the buyer
    	address buyer,
    	// the id of the token
    	uint256 tokenId,
    	// the price that the token was sold for
    	uint256 salePrice
    );

    // An event whenever a control token has been updated
    event ControlLeverUpdated (
    	// the address of who updated this control
    	address updater,
    	// the id of the token
    	uint256 tokenId,
        // the ids of the levers that were updated
        uint256[] leverIds,
    	// the previous values that the levers had before this update (for clients who want to animate the change)
    	int256[] previousValues,
    	// the new updated value
    	int256[] updatedValues
	);

    // struct for a token that controls part of the artwork
    struct ControlToken {
        // the containing artwork token that this control token belongs to
        uint256 containingArtworkTokenId;
        // the levers that this control token can use
        mapping (uint256 => ControlLever) levers;
        // number that tracks how many levers there are
        uint256 numControlLevers;
        // false by default, true once instantiated
        bool exists;
    }

    // struct for a lever on a control token that can be changed
    struct ControlLever {
        // // The minimum value this token can have (inclusive)
        int256 minValue;
        // The maximum value this token can have (inclusive)
        int256 maxValue;
        // The current value for this token
        int256 currentValue;
        // false by default, true once instantiated
        bool exists;
    } 

	// struct for a pending bid 
	struct PendingBid {
		// the address of the bidder
		address payable bidder;
		// the amount that they bid
		uint256 amount;
		// false by default, true once instantiated
		bool exists;
	}
    
    // map an artwork token id to the number of control tokens it contains
    mapping (uint256 => uint256) public numControlTokensMapping;
    // map an artwork token id to an array of its control token ids
    mapping (uint256 => uint256[]) public artworkControlTokensMapping;
    // map a control token id to a control token struct
    mapping (uint256 => ControlToken) public controlTokenIdMapping;
    // map an artwork token id to the artist address (for royalties)
    mapping (uint256 => address payable) public artistAddressMapping;
    // map control token ID to its buy price
	mapping (uint256 => uint256) public buyPrices;	
    // map a control token ID to its highest bid
	mapping (uint256 => PendingBid) public pendingBids;
    // track whether this token was sold the first time or not (used for determining whether to use first or secondary sale percentage)
    mapping (uint256 => bool) tokenDidHaveFirstSale;
    // only finalized artworks can be interacted with. All collaborating artists must confirm their token ID for a piece to finalize.
    mapping (uint256 => bool) tokenIsConfirmed;
    // the percentage of sale that the platform gets on first sales
    uint256 public platformFirstSaleRoyaltyPercentage;
    // the percentage of sale that the platform gets on secondary sales
    uint256 public platformSecondaryRoyaltyPercentage;
    // the percentage of sale that an artist gets on secondary sales
    uint256 public artistSecondaryRoyaltyPercentage;
    // the address of the platform (for receving commissions and royalties)
    address payable private platformAddress;

	constructor (string memory name, string memory symbol) public ERC721Full(name, symbol) {
        platformFirstSaleRoyaltyPercentage = 10;
        platformSecondaryRoyaltyPercentage = 1;
        artistSecondaryRoyaltyPercentage = 3;

        // by default, the platformAddress is the address that mints this contract
        platformAddress = _msgSender();
  	}

    // modifier for only allowing the platform to make a call
    modifier onlyPlatform() {
        require(_msgSender() == platformAddress, "Only platform");
        _;    
    }

    // Allows the current platform address to update to something different
    function updatePlatformAddress(address payable newPlatformAddress) public onlyPlatform {
        platformAddress = newPlatformAddress;

        emit PlatformAddressUpdated(newPlatformAddress);
    }

    // Update the royalty percentages that platform and artists receive on first or secondary sales
    function updateRoyaltyPercentages(uint256 _platformFirstSaleRoyaltyPercentage, uint256 _platformSecondaryRoyaltyPercentage, 
        uint256 _artistSecondaryRoyaltyPercentage) public onlyPlatform {
        // update the percentage that the platform gets on first sale
        platformFirstSaleRoyaltyPercentage = _platformFirstSaleRoyaltyPercentage;
        // update the percentage that the platform gets on secondary sales
        platformSecondaryRoyaltyPercentage = _platformSecondaryRoyaltyPercentage;
        // update the percentage that artists get on secondary sales
        artistSecondaryRoyaltyPercentage = _artistSecondaryRoyaltyPercentage;
        // emit an event that contains the new royalty percentage values
        emit RoyaltyAmountUpdated(platformFirstSaleRoyaltyPercentage, platformSecondaryRoyaltyPercentage, artistSecondaryRoyaltyPercentage);
    }

    // modifier to check if this artist is whitelisted and has a positive mint balance
    modifier onlyWhitelistedArtist() {
        // TODO check for whitelisted creator address
        _;
    }

    // Returns whether an artwork token has been confirmed. If a control token is passed in, check for the containing 
    // artwork and return whether that has been confirmed
    function isContainingArtworkConfirmed(uint256 artworkOrControlTokenId) public view returns (bool) {
        // if this is a control token
        if (controlTokenIdMapping[artworkOrControlTokenId].exists) {
            return tokenIsConfirmed[controlTokenIdMapping[artworkOrControlTokenId].containingArtworkTokenId];
        } else {
            return tokenIsConfirmed[artworkOrControlTokenId];
        }
    }
  	
    function setupControlToken(uint256 artworkTokenId, uint256 controlTokenId, string memory controlTokenURI,
            int256[] memory leverMinValues, 
            int256[] memory leverMaxValues,
            int256[] memory leverStartValues
        ) public onlyWhitelistedArtist {
        // check that a control token exists for this token id
        require (controlTokenIdMapping[controlTokenId].exists, "No control token found");
        // ensure that only the control token artist is attempting this mint
        require(artistAddressMapping[controlTokenId] == _msgSender(), "Must be control token artist");
        // ensure that this token is not confirmed yet
        require (tokenIsConfirmed[controlTokenId] == false, "Art must not be confirmed");       
        // enforce that the length of all the array lengths are equal
        require((leverMinValues.length == leverMaxValues.length) && (leverMaxValues.length == leverStartValues.length), "Values array mismatch");
        // set token URI
        super._setTokenURI(controlTokenId, controlTokenURI);        
        // create the control token
        controlTokenIdMapping[controlTokenId] = ControlToken(artworkTokenId, leverStartValues.length, true);
        // create the control token levers now
        for (uint256 k = 0; k < leverStartValues.length; k++) {
            // enforce that maxValue is greater than or equal to minValue
            require (leverMaxValues[k] >= leverMinValues[k], "Max val must >= min");
            // enforce that currentValue is valid
            require((leverStartValues[k] >= leverMinValues[k]) && (leverStartValues[k] <= leverMaxValues[k]), "Invalid start val");
            // add the lever to this token
            controlTokenIdMapping[controlTokenId].levers[k] = ControlLever(leverMinValues[k],
                leverMaxValues[k], leverStartValues[k], true);
        }
        // confirm this token
        tokenIsConfirmed[controlTokenId] = true;

        emit ControlTokenConfirmed(controlTokenId);

        bool allControlTokensConfirmed = true;
        // for each control token id
        for (uint256 k = 0; k < numControlTokensMapping[artworkTokenId]; k++) {
            if (tokenIsConfirmed[artworkControlTokensMapping[artworkTokenId][k]] == false) {
                allControlTokensConfirmed = false;
                break;
            }
        }
        // if all the control tokens for the containing artwork have been confirmed, then the containing artwork token sis confirmed
        if (allControlTokensConfirmed) {
            tokenIsConfirmed[artworkTokenId] = true;            
            
            emit ArtworkConfirmed(artworkTokenId);
        }
    }


  	// Mint a piece of artwork. _msgSender() must be a whitelisted artist and have a positive mint balance 
    function mintArtwork(uint256 artworkTokenId, string memory artworkTokenURI, address payable[] memory controlTokenArtists
    ) public onlyWhitelistedArtist {
        require (artworkTokenId == totalSupply(), "TotalSupply different");
        // Mint the token that represents ownership of the entire artwork    
        super._safeMint(_msgSender(), artworkTokenId);
        super._setTokenURI(artworkTokenId, artworkTokenURI);
        // track the number of control tokens that each artwork contains
        numControlTokensMapping[artworkTokenId] = controlTokenArtists.length;
        // track the _msgSender() address as the artist address for future royalties
        artistAddressMapping[artworkTokenId] = _msgSender();
        // iterate through all control token URIs (1 for each control token)
        for (uint256 i = 0; i < controlTokenArtists.length; i++) {
            // use the curren token supply as the next token id
            uint256 controlTokenId = totalSupply();
            // stub in an existing control token so exists is true
            controlTokenIdMapping[controlTokenId] = ControlToken(artworkTokenId, 0, true);
            // map the provided control token artist to its control token ID
            artistAddressMapping[controlTokenId] = controlTokenArtists[i];            
            // mint the control token
            super._safeMint(controlTokenArtists[i], controlTokenId);            
            // track the control ids mapped to each artwork token id
            artworkControlTokensMapping[artworkTokenId].push(controlTokenId);
        }
        if (controlTokenArtists.length == 0) {
            tokenIsConfirmed[artworkTokenId] = true;

            emit ArtworkConfirmed(artworkTokenId);
        }
    }

    // Bidder functions
    function bid(uint256 tokenId) public payable {
    	// don't let owners/approved bid on their own tokens
        require(_isApprovedOrOwner(_msgSender(), tokenId) == false, "Owners cant rebuy");
        // enforce that this artwork (or containing artwork if it's a control token) has been confirmed
        require(isContainingArtworkConfirmed(tokenId), "Art not confirmed");
    	// check if there's a high bid
    	if (pendingBids[tokenId].exists) {
    		// enforce that this bid is higher
    		require(msg.value > pendingBids[tokenId].amount, "Bid must be > than current bid");
            // Return bid amount back to bidder
            pendingBids[tokenId].bidder.transfer(pendingBids[tokenId].amount);
    	}
    	// set the new highest bid
    	pendingBids[tokenId] = PendingBid(_msgSender(), msg.value, true);
    	// Emit event for the bid proposal
    	emit BidProposed(_msgSender(), tokenId, msg.value);
    }

    // allows an address with a pending bid to withdraw it
    function withdrawBid(uint256 tokenId) public {
        // check that there is a bid from the sender to withdraw
        require (((pendingBids[tokenId].exists) && (pendingBids[tokenId].bidder == _msgSender())), "No bid to withdraw");
    	// Return bid amount back to bidder
        pendingBids[tokenId].bidder.transfer(pendingBids[tokenId].amount);
		// clear highest bid
		pendingBids[tokenId] = PendingBid(address(0), 0, false);
		// emit an event when the highest bid is withdrawn
		emit BidWithdrawn(_msgSender(), tokenId);
    }

    function distributeProceedsFromSale(uint256 tokenId, uint256 saleAmount) private {
        // the amount that the platform gets from this sale (depends on whether this is first sale or not)
        uint256 platformAmount = 0;
        uint256 hundred = 100;
        
        // if the first sale already happened, then give the artist + platform the secondary royalty percentage
        if (tokenDidHaveFirstSale[tokenId]) {
            // mark down that this first sale occurred
            tokenDidHaveFirstSale[tokenId] = true;
            // calculate the artist royalty
            uint256 artistAmount = hundred.sub(artistSecondaryRoyaltyPercentage).div(hundred).mul(saleAmount);
            // transfer the artist's royalty
            artistAddressMapping[tokenId].transfer(artistAmount);            
            // calculate the platform royalty
            platformAmount = hundred.sub(platformSecondaryRoyaltyPercentage).div(hundred).mul(saleAmount);
            // deduct the artist amount from the payment amount
            saleAmount = saleAmount.sub(artistAmount);
        } else {
            // else if this is the first sale for the token, give the platform the first sale royalty percentage
            platformAmount = hundred.sub(platformFirstSaleRoyaltyPercentage).div(hundred).mul(saleAmount);
        }
        // give platform its royalty
        platformAddress.transfer(platformAmount);
        // deduct the platform amount from the payment amount
        saleAmount = saleAmount.sub(platformAmount);
        // cast the owner to a payable address
        address payable payableOwner = address(uint160(ownerOf(tokenId)));
        // transfer the remaining amount to the owner of the token
        payableOwner.transfer(saleAmount);
    }

    // Buy the artwork for the currently set price
    function takeBuyPrice(uint256 tokenId) public payable {
        // don't let owners/approved buy their own tokens
        require(_isApprovedOrOwner(_msgSender(), tokenId) == false, "Owners can't rebuy");
        // get the sale amount
        uint256 saleAmount = buyPrices[tokenId];
        // check that there is a buy price
        require(saleAmount > 0, "No buy price");
        // check that the buyer sent enough to purchase
        require (msg.value >= saleAmount, "Not enough sent");
    	// Return all highest bidder's money
        if (pendingBids[tokenId].exists) {
            // Return bid amount back to bidder
            pendingBids[tokenId].bidder.transfer(pendingBids[tokenId].amount);
            // clear highest bid
            pendingBids[tokenId] = PendingBid(address(0), 0, false);
        }        
    	// Distribute percentage back to Artist(s) + Platform
        distributeProceedsFromSale(tokenId, saleAmount);
    	// Transfer token to _msgSender()
        safeTransferFrom(ownerOf(tokenId), _msgSender(), tokenId);
        // clear the approval for this token
        approve(address(0), tokenId);
        // Emit event
        emit TokenSale(_msgSender(), tokenId, saleAmount);
        // reset buy price
        buyPrices[tokenId] = 0;
        // clear highest bid
        pendingBids[tokenId] = PendingBid(address(0), 0, false);    	
    }

    // Owner functions
    // Allow owner to accept the highest bid for a token
    function acceptHighestBid(uint256 tokenId) public {
    	// check if sender is owner/approved of token        
        require(_isApprovedOrOwner(_msgSender(), tokenId), "Owner only");
    	// check if there's a bid to accept
    	require (pendingBids[tokenId].exists, "No bid found");

        // get the pending bid amount
        uint256 saleAmount = pendingBids[tokenId].amount;

        // distribute the proceeds from the sale
        distributeProceedsFromSale(tokenId, saleAmount);

        // transfer the token to the bidder address
        safeTransferFrom(ownerOf(tokenId), pendingBids[tokenId].bidder, tokenId);
        // clear the approval for this token
        approve(address(0), tokenId);
        // reset buy price
    	buyPrices[tokenId] = 0;
        // clear highest bid
        pendingBids[tokenId] = PendingBid(address(0), 0, false);
    	// Emit event
        emit TokenSale(pendingBids[tokenId].bidder, tokenId, saleAmount);        
    }

    // Allows owner of a control token to set an immediate buy price. Set to 0 to reset.
    function makeBuyPrice(uint256 tokenId, uint256 amount) public {
    	// check if sender is owner/approved of token        
    	require(_isApprovedOrOwner(_msgSender(), tokenId), "Owner only");
        // enforce that this artwork (or containing artwork if it's a control token) has been confirmed
        require(isContainingArtworkConfirmed(tokenId), "Art not confirmed");
    	// set the buy price
    	buyPrices[tokenId] = amount;
    	// emit event
    	emit BuyPriceSet(tokenId, amount);
    }

    // used during the render process to determine values
    function getControlLeverValue(uint256 controlTokenId, uint256 leverId) public view returns (int256) {
        // check that a control token exists for this token id
        require (controlTokenIdMapping[controlTokenId].exists, "No control token found");

        return controlTokenIdMapping[controlTokenId].levers[leverId].currentValue;
    }

    // used for token owners to know the range of values they can use for a control lever.
    function getControlLeverMinMax(uint256 controlTokenId, uint256 leverId) public view returns (int256[] memory) {
        // check that a control token exists for this token id
        require (controlTokenIdMapping[controlTokenId].exists, "No control token found");

        int256[] memory minMax = new int256[](2);

        minMax[0] = controlTokenIdMapping[controlTokenId].levers[leverId].minValue;
        minMax[1] = controlTokenIdMapping[controlTokenId].levers[leverId].maxValue;

        return minMax;
    }

    // Allows owner of a control token to update its lever values
    function useControlToken(uint256 controlTokenId, uint256[] memory leverIds, int256[] memory newValues) public {
        // check that a control token exists for this token id
        require (controlTokenIdMapping[controlTokenId].exists, "No control token found");
    	// check if sender is owner/approved of token        
        require(_isApprovedOrOwner(_msgSender(), controlTokenId), "Owner only");
        // enforce that this artwork (or containing artwork if it's a control token) has been confirmed
        require(isContainingArtworkConfirmed(controlTokenId), "Art not confirmed");
 
        // collect the previous lever values for the event emit below
        int256[] memory previousValues = new int256[](newValues.length);

        for (uint256 i = 0; i < leverIds.length; i++) {
            // get the control lever
            ControlLever storage lever = controlTokenIdMapping[controlTokenId].levers[leverIds[i]];

            // Enforce that the new value is valid        
            require((newValues[i] >= lever.minValue) && (newValues[i] <= lever.maxValue), "Invalid val");

            // Enforce that the new value is different
            require(newValues[i] != lever.currentValue, "Must provide different val");

            // grab previous value for the event emit
            int256 previousValue = lever.currentValue;
            
            // Update token current value
            lever.currentValue = newValues[i];

            // collect the previous lever values for the event emit below
            previousValues[i] = previousValue;
        }
        
    	// emit event
    	emit ControlLeverUpdated(_msgSender(), controlTokenId, leverIds, previousValues, newValues);
    }
}