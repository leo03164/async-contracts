pragma solidity ^0.5.12;

import "../node_modules/openzeppelin-solidity/contracts/token/ERC721/ERC721Full.sol";

contract AsyncArtwork is ERC721Full {
    // An event whenever an bid is withdrawn
    event PlatformAddressUpdated (
        address platformAddress
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
    // the percentage of sale that the platform gets on first sales
    uint256 public platformFirstSaleRoyaltyPercentage;
    // the percentage of sale that the platform gets on secondary sales
    uint256 public platformSecondaryRoyaltyPercentage;
    // the percentage of sale that an artist gets on secondary sales
    uint256 public artistSecondaryRoyaltyPercentage;
    // The amount of artwork + control tokens that have been minted
    uint256 private numTotalTokens;
    // the address of the platform (for receving commissions and royalties)
    address payable private platformAddress;

	constructor (string memory name, string memory symbol) public ERC721Full(name, symbol) {
        // TODO add functions to set these
        platformFirstSaleRoyaltyPercentage = 10;
        platformSecondaryRoyaltyPercentage = 1;
        artistSecondaryRoyaltyPercentage = 3;
  	}

    modifier onlyPlatform() {
        require(_msgSender() == platformAddress, "Only platform is allowed to perform this action.");
        _;    
    }

    // Allows the current platform address to update to something different
    function updatePlatformAddress(address payable newPlatformAddress) public onlyPlatform {
        platformAddress = newPlatformAddress;

        emit PlatformAddressUpdated(newPlatformAddress);
    }

    // modifier to check if this artist is whitelisted and has a positive mint balance
    modifier onlyWhitelistedArtist() {
        // TODO check for whitelisted creator address
        _;
    }

    // utility function to get a substring with a given start + end index
    function substring(string memory str, uint startIndex, uint endIndex) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        bytes memory result = new bytes(endIndex-startIndex);
        for(uint i = startIndex; i < endIndex; i++) {
            result[i-startIndex] = strBytes[i];
        }
        return string(result);
    }
  	
  	// Mint a piece of artwork. _msgSender() must be a whitelisted artist and have a positive mint balance 
    function mintArtwork(address to, string memory artworkTokenURI, 
        string memory newControlTokenURIs,
        uint256[] memory newControlTokenURIEndIndices,        
        uint256[] memory numLeversPerControlToken,
        uint256[] memory leverIds,
        int256[] memory minValues, 
        int256[] memory maxValues,
        int256[] memory startValues
    ) public onlyWhitelistedArtist {
        // enforce that at least 1 lever id is passed in
        require(leverIds.length > 0, "Must pass in at least 1 lever id.");
        // enforce that the length of all the array lengths are equal
        require((leverIds.length == minValues.length) && (minValues.length == maxValues.length) && (maxValues.length == startValues.length),
            "LeverIds, MinValues, MaxValues, and StartValues arrays must be same length.");
        // enforce that URI end indices is same length as levers per control token array (must be 1 URI for each control token)
        require(newControlTokenURIEndIndices.length == numLeversPerControlToken.length, 
            "newControlTokenURIEndIndices and numLeversPerControlToken must be same length.");

        // generate a new token ID from the current supply amount
        uint256 artworkTokenId = totalSupply();
        // increment the number of tokens that have been minted
        numTotalTokens = numTotalTokens.add(1);
        // Mint the token that represents ownership of the entire artwork    
        super._safeMint(to, artworkTokenId);
        super._setTokenURI(artworkTokenId, artworkTokenURI);
        // track the number of control tokens that each artwork contains
        numControlTokensMapping[artworkTokenId] = newControlTokenURIEndIndices.length;
        // track the _msgSender() address as the artist address for future royalties
        artistAddressMapping[artworkTokenId] = _msgSender();
        // index to track our control token lever values for min/max/start
        uint256 controlTokenLeverIndex = 0;
        // iterate through all control token URIs (1 for each control token)
        for (uint256 i = 0; i < numLeversPerControlToken.length; i++) {
            uint256 controlTokenId = totalSupply();
            // increment the number of tokens that have been minted
            numTotalTokens = numTotalTokens.add(1);

            // track the _msgSender() address as the artist address for future royalties
            artistAddressMapping[controlTokenId] = _msgSender();

            // mint the control token
            super._safeMint(to, controlTokenId);
            // set the URI
            if (i > 0) {
                super._setTokenURI(controlTokenId, substring(newControlTokenURIs, newControlTokenURIEndIndices[i - 1], newControlTokenURIEndIndices[i]));
            } else {
                super._setTokenURI(controlTokenId, substring(newControlTokenURIs, 0, newControlTokenURIEndIndices[i]));
            }

            // create the control token
            controlTokenIdMapping[controlTokenId] = ControlToken(numLeversPerControlToken[i], true);

            // track the control ids mapped to each artwork token id
            artworkControlTokensMapping[artworkTokenId].push(controlTokenId);

            // create the control token levers now
            for (uint256 k = 0; k < numLeversPerControlToken[i]; k++) {
                // enforce that maxValue is greater than or equal to minValue
                require (maxValues[controlTokenLeverIndex] >= minValues[controlTokenLeverIndex], "Max value must be greater than or equal to min value.");
                // enforce that currentValue is valid
                require((startValues[controlTokenLeverIndex] >= minValues[controlTokenLeverIndex]) && 
                    (startValues[controlTokenLeverIndex] <= maxValues[controlTokenLeverIndex]), "Invalid start value.");
                // add the lever to this token
                controlTokenIdMapping[controlTokenId].levers[k] = ControlLever(minValues[controlTokenLeverIndex],
                    maxValues[controlTokenLeverIndex], startValues[controlTokenLeverIndex], true);
                // increment the control token lever index
                controlTokenLeverIndex = controlTokenLeverIndex.add(1);
            }
        }
    }

    // Bidder functions
    function bid(uint256 tokenId) public payable {
    	// don't let owners/approved bid on their own tokens
        require(_isApprovedOrOwner(_msgSender(), tokenId) == false, "Token owners/approved can't bid on their own tokens.");
        // require a positive value for bid
        require (msg.value > 0, "Bids must be greater than zero.");
    	// check if there's a high bid
    	if (pendingBids[tokenId].exists) {
    		// enforce that this bid is higher
    		require(msg.value > pendingBids[tokenId].amount, "Bid must be higher than previous bid amount.");
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
        require (((pendingBids[tokenId].exists) && (pendingBids[tokenId].bidder == _msgSender())), "No bid from _msgSender() to withdraw.");
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
        require(_isApprovedOrOwner(_msgSender(), tokenId) == false, "Owners/approved can't buy their own token.");
        // get the sale amount
        uint256 saleAmount = buyPrices[tokenId];
        // check that there is a buy price
        require(saleAmount > 0, "No buy price set for this token.");
        // check that the buyer sent enough to purchase
        require (msg.value >= saleAmount, "Not enough to cover buy price.");
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
        require(_isApprovedOrOwner(_msgSender(), tokenId), "Only token owners/approved can accept bids.");
    	// check if there's a bid to accept
    	require (pendingBids[tokenId].exists, "No pending bid to accept!");

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
    	require(_isApprovedOrOwner(_msgSender(), tokenId), "Only token owner or approved can set buy price.");
    	// set the buy price
    	buyPrices[tokenId] = amount;
    	// emit event
    	emit BuyPriceSet(tokenId, amount);
    }

    // used during the render process to determine values
    function getControlLeverValue(uint256 tokenId, uint256 leverId) public view returns (int256) {
        return controlTokenIdMapping[tokenId].levers[leverId].currentValue;
    }

    // used for token owners to know the range of values they can use for a control lever.
    function getControlLeverMinMax(uint256 tokenId, uint256 leverId) public view returns (int256[] memory) {
        int256[] memory minMax = new int256[](2);

        minMax[0] = controlTokenIdMapping[tokenId].levers[leverId].minValue;
        minMax[1] = controlTokenIdMapping[tokenId].levers[leverId].maxValue;

        return minMax;
    }

    // Allows owner of a control token to update its lever values
    function useControlToken(uint256 tokenId, uint256[] memory leverIds, int256[] memory newValues) public {
    	// check if sender is owner/approved of token        
        require(_isApprovedOrOwner(_msgSender(), tokenId), "Control tokens only usuable by owners/approved.");

        // collect the previous lever values for the event emit below
        int256[] memory previousValues = new int256[](newValues.length);

        for (uint256 i = 0; i < leverIds.length; i++) {
            // get the control lever
            ControlLever storage lever = controlTokenIdMapping[tokenId].levers[leverIds[i]];

            // Enforce that the new value is valid        
            require((newValues[i] >= lever.minValue) && (newValues[i] <= lever.maxValue), "Invalid value.");

            // Enforce that the new value is different
            require(newValues[i] != lever.currentValue, "Must provide a different lever value.");

            // grab previous value for the event emit
            int256 previousValue = lever.currentValue;
            
            // Update token current value
            lever.currentValue = newValues[i];

            // collect the previous lever values for the event emit below
            previousValues[i] = previousValue;
        }
        
    	// emit event
    	emit ControlLeverUpdated(_msgSender(), tokenId, leverIds, previousValues, newValues);
    }
}