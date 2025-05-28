// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

using {exists, at, pushFront, pushBack, insertBefore, insertAfter, remove} for LinkedListQueue global;

struct Node {
    uint256 prev;
    uint256 next;
}

struct LinkedListQueue {
    mapping(uint256 => Node) nodes;
    uint256 head;
    uint256 tail;
    uint256 length;
}

/// @notice Error for token that does not exist.
/// @param id The id of the non-existent token.
error TokenDoesNotExist(uint256 id);

/// @notice Error for invalid id (0).
/// @param id The invalid id.
error InvalidId(uint256 id);

/// @notice Error for id already in use.
/// @param id The id that is already in use.
error IdAlreadyUsed(uint256 id);

/// @notice Error for cursor that does not exist.
/// @param id The id of the non-existent cursor.
error CursorDoesNotExist(uint256 id);

/// @notice Checks if _id is in the queue.
function exists(LinkedListQueue storage q, uint256 _id) view returns (bool) {
    return q.nodes[_id].prev != 0 || q.nodes[_id].next != 0 || _id == q.head || _id == q.tail;
}

/// @notice Returns the node with _id in O(1).
/// @dev Reverts if _id is not in the queue.
function at(LinkedListQueue storage q, uint256 _id) view returns (Node storage n) {
    require(exists(q, _id), TokenDoesNotExist(_id));
    n = q.nodes[_id];
}

/// @notice Pushes a new node to the front.
/// @dev Reverts if _id is zero or already in use.
function pushFront(LinkedListQueue storage q, uint256 _id) {
    require(_id != 0, InvalidId(_id));
    require(!exists(q, _id), IdAlreadyUsed(_id));

    Node storage n = q.nodes[_id];

    if (q.length == 0) {
        q.head = _id;
        q.tail = _id;
    } else {
        n.next = q.head;
        q.nodes[q.head].prev = _id;
        q.head = _id;
    }

    q.length++;
}

/// @notice Pushes a new node to the back.
/// @dev Reverts if _id is zero or already in use.
function pushBack(LinkedListQueue storage q, uint256 _id) {
    require(_id != 0, InvalidId(_id));
    require(!exists(q, _id), IdAlreadyUsed(_id));

    Node storage n = q.nodes[_id];

    if (q.length == 0) {
        q.head = _id;
        q.tail = _id;
    } else {
        q.nodes[q.tail].next = _id;
        n.prev = q.tail;
        q.tail = _id;
    }

    q.length++;
}

/// @notice Inserts a new node immediately before an existing node _cursor.
/// @dev Reverts if _id is zero or already used, or if _cursor doesn't exist.
function insertBefore(LinkedListQueue storage q, uint256 _cursor, uint256 _id) {
    require(exists(q, _cursor), CursorDoesNotExist(_cursor));
    require(_id != 0, InvalidId(_id));
    require(!exists(q, _id), IdAlreadyUsed(_id));

    Node storage curNode = q.nodes[_cursor];
    Node storage newNode = q.nodes[_id];

    // link in
    newNode.prev = curNode.prev;
    newNode.next = _cursor;
    curNode.prev = _id;

    if (newNode.prev != 0) {
        q.nodes[newNode.prev].next = _id;
    } else {
        // inserted at head
        q.head = _id;
    }
    q.length++;
}

/// @notice Inserts a new node immediately after an existing node _cursor.
/// @dev Reverts if _id is zero or already used, or if _cursor doesn't exist.
function insertAfter(LinkedListQueue storage q, uint256 _cursor, uint256 _id) {
    require(exists(q, _cursor), CursorDoesNotExist(_cursor));
    require(_id != 0, InvalidId(_id));
    require(!exists(q, _id), IdAlreadyUsed(_id));

    Node storage curNode = q.nodes[_cursor];
    Node storage newNode = q.nodes[_id];

    // link in
    newNode.prev = _cursor;
    newNode.next = curNode.next;
    curNode.next = _id;

    if (newNode.next != 0) {
        q.nodes[newNode.next].prev = _id;
    } else {
        // inserted at tail
        q.tail = _id;
    }
    q.length++;
}

/// @notice Removes the node with id `_id` in O(1).
/// @dev Reverts if queue is empty or `_id` is invalid.
function remove(LinkedListQueue storage q, uint256 _id) returns (Node memory n) {
    n = at(q, _id);

    // unlink
    if (n.prev != 0) {
        q.nodes[n.prev].next = n.next;
    } else {
        q.head = n.next;
    }
    if (n.next != 0) {
        q.nodes[n.next].prev = n.prev;
    } else {
        q.tail = n.prev;
    }

    delete q.nodes[_id];
    q.length--;
}
