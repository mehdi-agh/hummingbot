# distutils: language=c++
# distutils: sources=hummingbot/core/cpp/OrderBookEntry.cpp

import logging
import numpy as np

from decimal import Decimal
from typing import Dict
from hummingbot.logger import HummingbotLogger
from hummingbot.core.data_type.order_book_row import OrderBookRow

_logger = None
s_empty_diff = np.ndarray(shape=(0, 4), dtype="float64")
msamexOrderBookTrackingDictionary = Dict[Decimal, Dict[str, Dict[str, any]]]

cdef class msamexActiveOrderTracker:
    def __init__(self,
                 active_asks: msamexOrderBookTrackingDictionary = None,
                 active_bids: msamexOrderBookTrackingDictionary = None):
        super().__init__()
        self._active_asks = active_asks or {}
        self._active_bids = active_bids or {}

    @classmethod
    def logger(cls) -> HummingbotLogger:
        global _logger
        if _logger is None:
            _logger = logging.getLogger(__name__)
        return _logger

    @property
    def active_asks(self) -> msamexOrderBookTrackingDictionary:
        return self._active_asks

    @property
    def active_bids(self) -> msamexOrderBookTrackingDictionary:
        return self._active_bids

    # TODO: research this more
    def volume_for_ask_price(self, price) -> float:
        return NotImplementedError

    # TODO: research this more
    def volume_for_bid_price(self, price) -> float:
        return NotImplementedError

    def get_rates_and_quantities(self, entry) -> tuple:
        # price, quantity
        amount = float(Decimal(entry[1])) if len(str(entry[1]).replace('.', '')) > 0 else 0.0
        return float(Decimal(entry[0])), amount

    cdef tuple c_convert_diff_message_to_np_arrays(self, object message):
        cdef:
            dict content = message.content
            list content_keys = list(content.keys())
            list bid_entry = []
            list ask_entry = []
            str order_id
            str order_side
            str price_raw
            object price
            dict order_dict
            double timestamp = message.timestamp
            double amount = 0

        if "bids" in content_keys:
            bid_entry = content["bids"]
        if "asks" in content_keys:
            ask_entry = content["asks"]

        bids = s_empty_diff
        asks = s_empty_diff

        if len(bid_entry) > 0:
            bids = np.array(
                [[timestamp,
                  price,
                  amount,
                  message.update_id]
                 for price, amount in [self.get_rates_and_quantities(bid_entry)]],
                dtype="float64",
                ndmin=2
            )

        if len(ask_entry) > 0:
            asks = np.array(
                [[timestamp,
                  price,
                  amount,
                  message.update_id]
                 for price, amount in [self.get_rates_and_quantities(ask_entry)]],
                dtype="float64",
                ndmin=2
            )

        return bids, asks

    cdef tuple c_convert_snapshot_message_to_np_arrays(self, object message):
        cdef:
            float price
            float amount
            str order_id
            dict order_dict

        # Refresh all order tracking.
        self._active_bids.clear()
        self._active_asks.clear()
        timestamp = message.timestamp
        content = message.content

        for snapshot_orders, active_orders in [(content["bids"], self._active_bids), (content["asks"], self._active_asks)]:
            for entry in snapshot_orders:
                price, amount = self.get_rates_and_quantities(entry)
                active_orders[price] = amount

        # Return the sorted snapshot tables.
        cdef:
            np.ndarray[np.float64_t, ndim=2] bids = np.array(
                [[message.timestamp,
                  float(price),
                  float(self._active_bids[price]),
                  message.update_id]
                 for price in sorted(self._active_bids.keys())], dtype='float64', ndmin=2)
            np.ndarray[np.float64_t, ndim=2] asks = np.array(
                [[message.timestamp,
                  float(price),
                  float(self._active_asks[price]),
                  message.update_id]
                 for price in sorted(self._active_asks.keys(), reverse=True)], dtype='float64', ndmin=2)

        if bids.shape[1] != 4:
            bids = bids.reshape((0, 4))
        if asks.shape[1] != 4:
            asks = asks.reshape((0, 4))

        return bids, asks

    cdef np.ndarray[np.float64_t, ndim=1] c_convert_trade_message_to_np_array(self, object message):
        cdef:
            double trade_type_value = 1.0 if message.content["taker_type"] == "buy" else 2.0

        timestamp = message.timestamp
        content = message.content

        return np.array(
            [timestamp, trade_type_value, float(content["price"]), float(content["amount"])],
            dtype="float64"
        )

    def convert_diff_message_to_order_book_row(self, message):
        np_bids, np_asks = self.c_convert_diff_message_to_np_arrays(message)
        bids_row = [OrderBookRow(price, qty, update_id) for ts, price, qty, update_id in np_bids]
        asks_row = [OrderBookRow(price, qty, update_id) for ts, price, qty, update_id in np_asks]
        return bids_row, asks_row

    def convert_snapshot_message_to_order_book_row(self, message):
        np_bids, np_asks = self.c_convert_snapshot_message_to_np_arrays(message)
        bids_row = [OrderBookRow(price, qty, update_id) for ts, price, qty, update_id in np_bids]
        asks_row = [OrderBookRow(price, qty, update_id) for ts, price, qty, update_id in np_asks]
        return bids_row, asks_row
